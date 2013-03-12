#!/usr/bin/env perl

# Todo: Add simple Blogging-Tool!

use File::Basename 'dirname';
use File::Spec;
BEGIN {
  my @libdir = File::Spec->splitdir(dirname(__FILE__));
  use lib join '/', @libdir, 'lib';
  use lib join '/', @libdir, '..', 'lib';
};
use Mojolicious::Lite;
use Mojo::ByteStream 'b';
use Mojo::Collection 'c';
use Mojo::Date;
use Mojo::Log;
use DBI;
use DBD::SQLite;

our $message_log = Mojo::Log->new(
  path  => 'incoming.log',
  level => 'info',
);

helper dbh => sub {
  return DBI->new( ... );
};

# Also loads callback plugin
plugin 'PubSubHubbub';

app->callback(pubsub_accept => sub {
  my ($c, $type) = @_;

  # create quoted topic string
  my $topic_string = join(',', map(b($_)->quote, grep { $_ } @$topics));

  # Get topics and associated secrets
  my $db_request = <<"SELECT_TOPICS";
SELECT
  topic, secret FROM PubSub
WHERE
  topic in ($topic_string)
  AND mode = "subscribe"
  AND pending = 0
  AND (
    lease_seconds is NULL
    OR (started + lease_seconds) <= date("now")
  )
SELECT_TOPICS

  my $dbh = $c->dbh;
  my $array = $dbh->selectall_arrayref($db_request);

  # Todo: Is the hub the one I subscribed to?

  my (%topics, $secret);

  # Iterate through all topics
  foreach (@$array) {

    # No secret needed
    unless ($_->[1]) {

      # Topic is valid
      $topics{$_->[0]} = 1;
    }

    # Secret needed
    else {

      # No secret given
      if (!$secret) {

	# Init secret
	$secret = $_->[1] if $_->[1];
      }

      # Secret already given and mismatched for bulk
      elsif ($secret ne $_->[1]) {
	$c->app->log->info(
	  "Hub for topics $topic_string expects " .
	  'different secrets for bulk.');
	next;
      };

      # Secret match for bulk
      $topics{$_->[0]} = 1;
    };
  };

  # Return filtered topics and secret
  return ([keys %topics], $secret);
});

app->callback(pubsub_verify => sub {
  my ($c, $params) = @_;

  my $dbh = $c->dbh;

  # Get subsrciption
  my $subscr = $dbh->selectrow_hashref(
    'SELECT FROM PubSub WHERE topic = ? AND mode = ? AND verify_token = ?',
    @{$params}{qw/topic mode verify_token/}
  );

  # No subscription of this topic found
  return unless $row;

  $dbh->begin_work;

  # Is subscription time over?
  if ($subscr->{lease_seconds} &&
	(time > ($subscr->{started} + $subscr->{lease_seconds}))) {

    # Delete Subscription (Maybe too hard?)
    unless ($dbh->do('DELETE FROM PubSub WHERE id = ?', $subscr->{id})) {
      $dbh->rollback and return;
    };
  };

  # If mode is subscribe and pending, update pending status

  # Maybe
  if ($subscr->{pending} && $subscr->{mode} eq 'subscribe') {
    unless ($dbh->do(
      'UPDATE PubSub SET pending = 0 WHERE id = ?', $subscr->{id}
    )) {
      $dbh->rollback and return;
    }
  }

  # If mode is unsubscribe, delete subscription
  # Maybe this is wrong?
  elsif ($subscr->{mode} eq 'unsubscribe') {

    # Delete subscription
    unless ($dbh->do('DELETE FROM PubSub WHERE id = ?', $subscr->{id})) {
      $dbh->rollback and return;
    };
  };

  # Everything is fine
  $dbh->commit;

  # Verify subscription
  return 1;
});


hook on_pubsub_content => sub {
  my ($c, $type, $dom) = @_;

  my (@feed, $elem);

  # Feed is Atom
  if ($type eq 'atom') {

    $elem = $dom->at('author > name');
    my $author = $elem ? $elem->all_text : undef;

    $dom->find('entry')->each(
      sub {
	my $entry = shift;

	my %info = (
	  topic => $entry->at('source > link[rel="self"]')->attrs('href')
	);

	foreach (qw/title id updated content/) {
	  $elem = $entry->at($_);
	  $_ = 'guid' if $_ eq 'id';
	  $info{$_} = $elem ? $elem->all_text : '';
	};

	$elem = $entry->at('author entry');
	$info{author} = $elem->all_text || $author;
	$info{updated} = $info{updated} ?
	  Mojolicious::Plugin::Date::RFC3339->new( $info{updated} )->epoch
	      : time;

	push(@feed, \%info);
      }
    );
  }

  # Feed is RSS
  elsif ($type eq 'rss') {

    $dom->find('item')->each(
      sub {
	my $entry = shift;

	my %info = (
	  topic => $entry->at('source > link[rel="self"]')->attrs('href')
	);

	foreach (qw/title guid pubDate author description/) {
	  $elem = $entry->at($_);

	  # Rename pubDate
	  if ($_ eq 'pubDate') {
	    $_ = 'updated';
	  }

	  # Rename description
	  elsif ($_ eq 'description') {
	    $_ = 'content';
	  };

	  $info{$_} = $elem ? $elem->all_text || '';
	};

	# Set updated to epoch time
	$info{updated} =
	  $info{updated} ? Mojo::Date->new($info{updated})->epoch : time;

	push(@feed, \%info);
      });
  };

  $dbh = $c->dbh;
  my $sth = $dbh->prepare(
    'INSERT INTO Content ' .
      '(topic, author, updated, title, content) ' .
	'VALUES ' .
	  '(?,?,?,?,?)'
  );

  # Start transaction
  $dbh->begin_work;

  # Import all entries to database
  foreach my $entry (@feed) {
    $sth->execute(@{$entry}{qw/topic author updated title content/});
  };

  # Commit insertions
  $dbh->commit;
};

sub _store_subscription {
  my ($c, $params, $post) = @_;

  my %cond;
  $cond{$_}  = delete $params->{$_} for (qw/topic mode/);

  # Filter parameters
  my %params = map { $_ => $params->{$_} }
    qw(hub lease_seconds secret verify_token mode);

Todo :::::::::::::::::::::::::::::::::::::::::::::

  # Save new status
  $c->oro->merge(
    'PubSub' => {
      %params,
      started => time,
      pending => 1
    } => \%cond
  );
};

hook before_pubsub_subscribe => \&_store_subscription;

hook before_pubsub_unsubscribe => \&_store_subscription;


##############
# Set routes #
##############
(any '/ps-callback')->pubsub;

# Show last content and subscription form
get '/' => sub {
  my $c = shift;
  # Todo: Get all feeds I subscribed to
  # Todo: Get latest entries
};

# Subscribe to new feed
post '/' => sub {
  my $c = shift;

  my $hub    = $c->param('hub');
  my $feed   = $c->param('feed');
  my $secret = $c->param('secret');

  # Missing information
  unless ($hub && $feed) {

    # Set information to flash
    $c->flash(
      hub    => $hub,
      feed   => $feed,
      secret => $secret
    );

    # Retry
    return $c->redirect_to('/');
  };

  # Create new parameter hash
  my %new_param = (
    topic => $feed,
    hub   => $hub
  );

  # Set secret
  $new_param{secret} = $secret if $secret;

  # Subscribe to new feed
  if ($c->pubsub_subscribe( %new_param )) {
    $c->flash(message => 'You subscribed to ' . $feed);
  }

  # Failed to subscribe to new feed
  else {
    $c->flash(message => 'Unable to subscribe to ' . $feed);
  };

  # Redirect
  return $c->redirect_to('/');
};

#######################
# Initialize Database #
#######################

sub _init_db {
  $dbh->begin_work;

  unless ($dbh->do(
    'CREATE TABLE PubSub_content (
       id       INTEGER PRIMARY KEY,
       author   TEXT,
       guid     TEXT,
       title    TEXT,
       updated  INTEGER,
       content  TEXT
     )')) {
    $dbh->rollback and return;
  };

  # PubSub Indices
  foreach (qw/guid updated/) {
    unless ($dbh->do(
      "CREATE INDEX IF NOT EXISTS pubsub_content_${_}_i on PubSub_content (${_})"
    )) {
      $dbh->rollback and return;
    }
  };

  unless ($dbh->do(
    'CREATE TABLE PubSub (
       id            INTEGER PRIMARY KEY,
       topic         TEXT NOT NULL,
       mode          TEXT NOT NULL,
       hub           TEXT,
       pending       INTEGER,
       lease_seconds INTEGER,
       secret        TEXT,
       verify_token  TEXT,
       started       INTEGER
     )'
  )) {
    $dbh->rollback and return;
  };

  # PubSub Indices
  unless ($dbh->do(
    'CREATE INDEX IF NOT EXISTS pubsub_topic_i on PubSub (topic)'
  )) {
    $dbh->rollback and return;
  };

  $dbh->commit and return 1;
};

app->start;

__DATA__

@@ layouts/index.html.ep
<!doctype html>
<html>
  <head>
    <title><%= $title %></title>
  </head>
  <body>
    <h1><%= $title %></h1>
<%== content %>
  </body>
</html>

@@ index.html.ep
% layout 'index', title => 'Add Hub';

% my $subs = stash('subscriptions') || [];
% my $content = stash('entries') || [];

<h1>New Subscription</h1>
<form method="post" action="/">
% foreach (qw/feed hub secret/) {
  <label for="<%= $_ %>"><%= ucfirst($_) %></label>
  <input type="text" name="<%= $_ %>" id="<%= $_ %>" value="<%= flash($_) %>" />
  <br />
% }
  <input type="submit" value="OK" />
</form>

<h1>Subscriptions</h1>
% foreach my $sub ( @$subs ) {
<p>
  <%= $sub->{topic} %>
  <a hre="/unsubscribe/<%= $sub->{id} %>">unsubscribe</a>
</p>
% };

<h1>Content</h1>
% foreach my $entry ( @$content ) {
<h2><%= $entry->{title} %></h2>
<p><%= substr($entry->{content},200) %></p>
<p style="font-size: 60%">von <%= $entry->{author} %>,

% my $date = $entry->{updated} ?
%    Mojolicious::Plugin::Date::RFC3339->new($entry->{updated})->to_string : '';

   <%= $date  %></p>
% };
