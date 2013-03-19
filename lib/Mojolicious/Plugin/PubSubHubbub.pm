package Mojolicious::Plugin::PubSubHubbub;
use Mojo::Base 'Mojolicious::Plugin';
use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::DOM;
use Mojo::Util qw/secure_compare hmac_sha1_sum/;

our $VERSION = '0.03';

use constant ATOM_NS => 'http://www.w3.org/2005/Atom';

# Todo:
# - Test with http://push-pub.appspot.com/
# - Make everything async


# Default lease seconds before automatic subscription refreshing
has 'lease_seconds' => ( 7 * 24 * 60 * 60 );
has hub => 'http://pubsubhubbub.appspot.com/';


# Character set for challenge
my @CHALLENGE_CHARS = ('A' .. 'Z', 'a' .. 'z', 0 .. 9 );

my $FEED_TYPE_RE   = qr{^(?i:application/(atom|r(?:ss|df))\+xml)};
my $FEED_ENDING_RE = qr{(?i:\.(r(?:ss|df)|atom))$};

# User Agent Name
my $UA_NAME = __PACKAGE__ . ' v' . $VERSION;


# Register plugin
sub register {
  my ($plugin, $mojo, $param) = @_;

  $param ||= {};

  # Load parameter from Config file
  if (my $config_param = $mojo->config('PubSubHubbub')) {
    $param = { %$config_param, %$param };
  };

  my $helpers = $mojo->renderer->helpers;

  # Load 'callback' plugin
  unless (exists $helpers->{'callback'}) {
    $mojo->plugin('Util::Callback');
  };

  # Set callbacks on registration
  $mojo->callback([qw/pubsub_accept pubsub_verify/] => $param);

  # Load 'endpoint' plugin
  unless (exists $helpers->{'endpoint'}) {
    $mojo->plugin('Util::Endpoint');
  };

  # Set hub attribute
  if ($param->{hub}) {
    $plugin->hub($param->{hub});
  };

  # Establish an endpoint
  $mojo->endpoint('pubsub-hub' => $plugin->hub);

  # Set lease_seconds attribute
  if ($param->{lease_seconds}) {
    $plugin->lease_seconds($param->{lease_seconds});
  };

  # push (@{ $mojo->renderer->classes }, __PACKAGE__);

  # Add 'pubsub' shortcut
  $mojo->routes->add_shortcut(
    pubsub => sub {
      my ($route, $param) = @_;

      # Set param default to 'cb'
      $param ||= 'cb';

      # 'hub' is currently not supported
      return unless $param eq 'cb';

      # Set PubSubHubbub endpoints
      $route->endpoint('pubsub-callback');

      # Add 'callback' route
      $route->to(
	cb => sub {
	  my $c = shift;

	  # Hook on verification
	  return $plugin->verify($c) if $c->param('hub.mode');

	  # Hook on callback
	  return $plugin->callback($c);
	});
    });

  # Add 'publish' helper
  $mojo->helper(
    pubsub_publish => sub {
      $plugin->publish( @_ );
    });

  # Add 'subscribe' and 'unsubscribe' helper
  foreach my $action (qw(subscribe unsubscribe)) {
    $mojo->helper(
      "pubsub_${action}" => sub {
	$plugin->_change_subscription(shift, mode => $action, @_);
      });
  };

  # Add 'discovery' helper
  $mojo->helper(
    pubsub_discover => sub {
      $plugin->discover( @_ )
    }
  );
};


# Ping a hub for topics
sub publish {
  my $plugin = shift;
  my $c      = shift;

  # Nothing to publish or no hub defined
  return unless @_ || !$plugin->hub;

  # Set all urls
  my @urls = map($c->endpoint($_), @_);

  # Create post message
  my %post = (
    'hub.mode' => 'publish',
    'hub.url'  => \@urls
  );

  # Get user agent
  my $ua = Mojo::UserAgent->new(
    max_redirects => 3,
    name => $UA_NAME
  );

  # Post to hub
  my $res = $ua->post( $plugin->hub => form => \%post )->res;

  # No response
  unless ($res) {
    $c->app->log->debug('Cannot ping hub - maybe no SSL support')
      if index($plugin->hub, 'https') == 0;
    return;
  };

  # is 2xx, incl. 204 aka successful
  return 1 if $res->is_status_class(200);

  # Not successful
  return;
};


# Verify a changed subscription or automatically refresh
sub verify {
  my $plugin = shift;
  my $c = shift;

  # Good request
  if ($c->param('hub.topic') &&
      $c->param('hub.challenge') &&
      $c->param('hub.mode') =~ /^(?:un)?subscribe$/) {

    my $challenge = $c->param('hub.challenge');

    my %param;
    foreach (qw/mode
		topic
		verify
		lease_seconds
		verify_token/) {
      $param{$_} = $c->param("hub.$_") if $c->param("hub.$_");
    };

    # Get verification callback
    my $ok = $c->callback(
      pubsub_verify => \%param
    );

    return $c->render(
      'status' => 200,
      'format' => 'text',
      'data'   => $challenge
    ) if $ok;
  };

  # Not found
  return $c->render_not_found;
};


# Discover links from header
# This is extremely simplified from https://tools.ietf.org/html/rfc5988
sub _discover_header_links {
  my $header = shift;

  my %links;

  # Iterate through all header links
  foreach ($header->header('link')) {

    # Make multiline headers one line
    $_ = join(' ', @$_);

    # Check for link with correct relation
    if ($_ =~ /^\<([^>]+?)\>(.*?rel\s*=\s*"(self|hub|alternate)".*?)$/mi) {

      # Create new link hash
      my %link = ( href => $1, rel  => $3 );

      # There may be more than one reference
      my $check = $2;

      # Set type
      if ($check =~ /type\s*=\s*"([^"]+?)"/omi) {
	my $type = $1;
	next if $type && $type !~ $FEED_TYPE_RE;
	$link{type} = $type;
	$link{short_type} = $1;
      };

      # Set title
      if ($check =~ /title\s*=\s*"([^"]+?)"/omi) {
	$link{title} = $1;
      };

      # Check file ending for short type
      unless ($link{short_type}) {
	$link{short_type} = $1 if $link{href} =~ $FEED_ENDING_RE;
      };

      # Push found link
      my $rel = $link{rel};
      $links{$rel} //= [];
      push(@{$links{$rel}}, \%link);
    };
  };

  # Return array
  return \%links;
};


# Discover links from dom tree
sub _discover_dom_links {
  my $dom = shift;

  my %links;

  # Find alternate representations
  $dom->find('link[rel="alternate"], link[rel="self"], link[rel="hub"]')->each(
    sub {
      my ($href, $rel, $type, $title) = @{$_->attrs}{qw/href rel type title/};

      # Is no supported type
      return if $type && $type !~ $FEED_TYPE_RE;

      # Set short type
      my $short_type = $1 if $1;

      return unless $href && $rel;

      # Create new link hash
      my %link = ( href => $href, rel  => $rel );

      # Short type yet not known
      unless ($short_type) {

	# Set short type by file ending
	$link{short_type} = $1 if $href =~ m/\.(r(?:ss|df)|atom)$/i;
      }

      # Set short type
      else {
	$link{short_type} = $short_type;
      };

      # Set title and type
      $link{title} = $title if $title;
      $link{type}  = $type if $type;

      # Push found link
      $links{$rel} //= [];
      push(@{$links{$rel}}, \%link);
    }
  );

  # Return array
  return \%links;
};


# Heuristically sort links to best match the topic
sub _discover_sort_links {
  my $links = shift;

  my ($topic, $hub);

  # Get self link as topic
  if ($links->{self}) {

    # Find best match of all returned links
    foreach my $link (@{$links->{self}}) {
      $topic ||= $link;
      if ($link->{short_type} && !$topic->{short_type}) {
	$topic = $link;
      };
    };
  };

  # Get hub
  if ($links->{hub}) {

    # Find best match of all returned links
    foreach my $link (@{$links->{hub}}) {
      $hub ||= $link;
      if ($link->{short_type} && !$hub->{short_type}) {
	$hub = $link;
      };
    };
  };

  # Already found topic and hub
  return ($topic, $hub) if $topic && $hub;

  # Check alternates
  my $alternate = $links->{alternate};

  # Search in alternate representations for best match
  if ($alternate) {

    # Iterate through all alternate links and check their titles
    foreach my $link (@$alternate) {

      # No title given
      unless ($link->{title}) {
	$link->{pref} = 2;
      }

      # Guess which feed is best based on the title
      elsif ($link->{title} =~ /(?i:feed|stream)/i) {

	# This is more likely a comment feed
	if ($link->{title} =~ /[ck]omment/i) {
	  $link->{pref} = 1;
	}

	# This may be the correct feed
	else {
	  $link->{pref} = 3;
	};
      }

      # Don't know ...
      else {
	$link->{pref} = 2;
      };
    };

    # Get best topic
    ($topic) = (sort {

      # Sort by title
      if ($a->{pref} < $b->{pref}) {
	return 1;
      } elsif ($a->{pref} > $b->{pref}) {
	return -1;
      }
      # Sort by type
      elsif ($a->{short_type} gt $b->{short_type}) {
	return 1;
      } elsif ($a->{short_type} lt $b->{short_type}) {
	return -1;
      }
      # Sort by length
      elsif (length($a->{href}) > length($b->{href})) {
	return 1;
      } elsif (length($a->{href}) <= length($b->{href})) {
	return -1;
      }
      # Equal
      else {
	return -1;
      };
    } values @$alternate);
  };

  # Maybe empty ... maybe not
  return ($topic, $hub);
};


# Discover topic and hub based on an URI
# That's a rather complex heuristic, but should gain good results
sub discover {
  my $self = shift;
  my $c = shift;

  # Get uri
  my $base = Mojo::URL->new( shift );

  # Initialize UserAgent
  my $ua = Mojo::UserAgent->new(
    max_redirects => 3,
    name => $UA_NAME
  );

  # Retrieve resource
  my $tx = $ua->get($base);

  # Initialize variables
  my ($hub, $topic, $nbase, $ntopic);

  if ($tx->success) {

    # Change base after possible redirects
    $base = $tx->req->url;

    # Get response
    my $res = $tx->res;

    # Check sorted header links
    ($topic, $hub) = _discover_sort_links(
      _discover_header_links($res->headers)
    );

    # Fine
    goto STOPDISCOVERY if $topic && $hub;

    my $dom = $res->dom;

    # Check sorted dom links
    ($topic, $hub) = _discover_sort_links(
      _discover_dom_links($dom)
    );

    # Fine
    goto STOPDISCOVERY if ($topic && $hub) || !$topic;

    # Initialize new UserAgent
    $ua = Mojo::UserAgent->new(
      max_redirects => 3,
      name => $UA_NAME
    );

    # Set new base base
    $nbase = Mojo::URL->new($topic->{href});

    # Retrieve resource
    $tx = $ua->get($nbase);

    # Request was successful
    if ($tx->success) {

      # Change nbase after possible redirects
      $nbase = $tx->req->url;

      # Get response
      $res = $tx->res;

      # Check sorted header links
      ($ntopic, $hub) = _discover_sort_links(
	_discover_header_links($res->headers)
      );

      # Fine
      goto STOPDISCOVERY if $topic && $hub;

      # Check sorted dom links
      ($ntopic, $hub) = _discover_sort_links(
	_discover_dom_links($res->dom)
      );
    }

    # Reset nbase as no connection occurred
    else {
      $nbase = undef;
    };
  };

  # All requests are finished

 STOPDISCOVERY:

  # Make relative path for topics and hubs absolute
  $hub = Mojo::URL->new($hub->{href})->base( $nbase || $base )->to_abs if $hub;

  # New topic is set
  if ($ntopic) {
    $topic = Mojo::URL->new($ntopic->{href})->base($nbase)->to_abs;
  }

  # Old topic is set
  elsif ($topic) {
    $topic = Mojo::URL->new($topic->{href})->base($base)->to_abs;
  };

  # Return
  return ($topic, $hub);
};


# subscribe or unsubscribe from a topic
sub _change_subscription {
  my $plugin = shift;
  my $c      = shift;
  my %param  = @_;

  # Get callback endpoint
  # Works only if endpoints provided
  unless ($param{callback} = $c->endpoint('pubsub-callback')) {
    $c->app->log->warn('You have to specify a callback endpoint.');
  };

  # No topic or hub url given
  unless (exists $param{topic} &&
	    $param{topic} =~ m{^https?://}i &&
	      exists $param{hub}) {
    return;
  };

  my $mode = $param{mode};

  # delete lease seconds if no integer
  if (exists $param{lease_seconds} &&
	($mode eq 'unsubscribe' || $param{lease_seconds} !~ /^\d+$/)
      ) {
    delete $param{lease_seconds};
  };

  # Set to default
  $param{lease_seconds} ||= $plugin->lease_seconds if $mode eq 'subscribe';

  # Render post string
  my %post = ( callback => $param{callback} );
  foreach ( qw/mode topic verify lease_seconds secret/ ) {
    $post{ $_ } = $param{ $_ } if exists $param{ $_ } && $param{ $_ };
  };

  # Use verify token
  $post{verify_token} =
    exists $param{verify_token} ?
      $param{verify_token} :
	($param{verify_token} = _challenge(12));

  $post{verify} = "${_}sync" foreach ('a', '');

  my $mojo = $c->app;

  $mojo->plugins->emit_hook(
    "before_pubsub_$mode" => ($c, \%param, \%post)
  );

  # Prefix all parameters
  %post = map { 'hub.' . $_ => $post{$_} } keys %post;

  # Get user agent
  my $ua = Mojo::UserAgent->new(
    max_redirects => 3,
    name => $UA_NAME
  );

  # Send subscription change to hub
  my $tx = $ua->post($param{hub} => form => \%post);

  my $res = $tx->res if $tx->success;

  # No response
  unless ($tx->success && $res) {
    $mojo->log->debug('Cannot ping hub - maybe no SSL support installed?')
      if index($param{hub}, 'https') == 0;
    return;
  };

  my $res = $tx->res;

  $mojo->plugins->emit_hook(
    "after_pubsub_$mode" => (
      $c, \%param, $res->code, $res->body
    ));

  # is 2xx, incl. 204 aka successful and 202 aka accepted
  my $success = $res->is_status_class(200) ? 1 : 0;

  return ($success, $res->{body}) if wantarray;
  return $success;
};


# Incoming data callback
sub callback {
  my $plugin = shift;
  my $c      = shift;
  my $mojo   = $c->app;

  my $ct = $c->req->headers->header('Content-Type') || 'unknown';
  my $type;

  # Is Atom
  if ($ct eq 'application/atom+xml') {
    $type = 'atom';
  }

  # Is RSS
  elsif ($ct =~ m{^application/r(?:ss|df)\+xml$}) {
    $type = 'rss';
  }

  # Unsupported content type
  else {
    $mojo->log->debug("Unsupported media type: $ct");
    return _render_fail($c);
  };

  my $dom = Mojo::DOM->new(xml => 1);
  $dom->parse($c->req->body);

  # Find topics in Payload
  my $topics = _find_topics($type, $dom);

  # No topics to process - but technically fine
  return _render_success($c) unless $topics->[0];

  # Save unfiltered topics for later comparison
  my @old_topics = @$topics;

  # Check for secret and which topics are wanted
  ($topics, my $secret, my $x_hub_on_behalf_of) =
    $c->callback(pubsub_accept => $type, $topics);

  $x_hub_on_behalf_of ||= 1;

  # No topics to process
  # return _render_success( $c => $x_hub_on_behalf_of )
  return _render_success( $c => 1 ) unless scalar @$topics;

  # Todo: Async with on(finish => ..)

  # Secret is needed
  if ($secret) {

    # Unable to verify secret
    unless ( _check_signature( $c, $secret )) {

      $mojo->log->debug(
	'Unable to verify secret for ' . join('; ', @$topics)
      );

      # return _render_success( $c => $x_hub_on_behalf_of );
      return _render_success( $c => 1 );
    };
  };

  # Some topics are unwanted
  if (@$topics != @old_topics) {

    # filter dom based on topics
    $topics = _filter_topics($dom, $topics);
  };

  $mojo->plugins->emit_hook(
    on_pubsub_content => $c, $type, $dom
  );

  # Successful
  return _render_success( $c => $x_hub_on_behalf_of );
};


# Find topics of entries
sub _find_topics {
  my $type = shift;
  my $dom  = shift;

  # Get all source links
  my $links = $dom->find('source > link[rel="self"][href]');

  # Save href as topics
  my @topics = @{ $links->map( sub { $_->attrs('href') } ) } if $links;

  # Find all entries, regardless if rss or atom
  my $entries = $dom->find('item, feed > entry');

  # Not every entry has a source
  if ($links->size != $entries->size) {

    # One feed or entry
    my $link = $dom->at(
      'feed > link[rel="self"][href],' .
	'channel > link[rel="self"][href]'
      );

    my $self_href;

    # Channel or feed link
    if ($link) {
      $self_href = $link->attrs('href');
    }

    # Source of first item in RSS
    elsif (!$self_href && $type eq 'rss') {

      # Possible
      $link = $dom->at('item > source');
      $self_href = $link->attrs('url') if $link;
    };

    # Add topic to all entries
    _add_topics($type, $dom, $self_href) if $self_href;

    # Get all source links
    $links = $dom->find('source > link[rel="self"][href]');

    # Save href as topics
    @topics = @{ $links->map( sub { $_->attrs('href') } ) } if $links;
  };

  # Unify list
  if (@topics > 1) {
    my %topics = map { $_ => 1 } @topics;
    @topics = keys %topics;
  };

  return \@topics;
};


# Add topic to entries
sub _add_topics {
  my ($type, $dom, $self_href) = @_;

  my $link = qq{<link rel="self" href="$self_href" />};

  # Add source information to each entry
  $dom->find('item, entry')->each(
    sub {
      my $entry = shift;
      my $source;

      # Sources are found
      if (my $sources = $entry->find('source')) {
	foreach my $s (@$sources) {
	  $source = $s and last if $s->namespace eq ATOM_NS;
	};
      };

      # No source found
      unless ($source) {
	$source = $entry->append_content('<source xmlns="' . ATOM_NS . '" />')
	  ->at('source[xmlns=' . ATOM_NS . ']');
      }

      # Link already there
      elsif ($source->at('link[rel="self"][href]')) {
	return $dom;
      };

      # Add link
      $source->append_content( $link );
    });

  return $dom;
};


# filter entries based on their topic
sub _filter_topics {
  my $dom     = shift;

  my %allowed = map { $_ => 1 } @{ shift(@_) };

  my $links = $dom->find(
    'feed > entry > source > link[rel="self"][href],' .
      'item  > source > link[rel="self"][href]'
    );

  my %topics;

  # Delete entries that are not allowed
  $links->each(
    sub {
      my $l = shift;
      my $href = $l->attrs('href');

      unless (exists $allowed{$href}) {
	$l->parent->parent->replace('');
      }

      else {
	$topics{$href} = 1;
      };
    });

  return [ keys %topics ];
};


# Check signature
sub _check_signature {
  my ($c, $secret) = @_;

  my $req = $c->req;

  # Get signature
  my $signature = $req->headers->header('X-Hub-Signature');

  # Signature expected but not given
  return unless $signature;

  # Delete signature prefix - don't remind, if it's not there.
  $signature =~ s/^sha1=//i;

  # Generate check signature
  my $signature_check = hmac_sha1_sum $req->body, $secret;

  # Return true  if signature check succeeds
  return secure_compare $signature, $signature_check;
};


# Render success
sub _render_success {
  my $c = shift;
  my $x_hub_on_behalf_of = shift;

  # Set X-Hub-On-Behalf-Of header
  if ($x_hub_on_behalf_of &&
      $x_hub_on_behalf_of =~ s/^\s*(\d+)\s*$/$1/) {

    # Set X-Hub-On-Behalf-Of header
    $c->res->headers->header(
      'X-Hub-On-Behalf-Of' => $x_hub_on_behalf_of
    );
  };

  # Render success with no content
  return $c->render(
    status => 204,
    format => 'text',
    data   => ''
  );
};


# Render fail
sub _render_fail {
  my $c = shift;

  my $fail =<<'FAIL';
<!doctype html>
<html>
  <head>
    <title>PubSubHubbub Endpoint</title>
  </head>
  <body>
    <h1>PubSubHubbub Endpoint</h1>
    <p>
      This is an endpoint for the
      <a href="http://pubsubhubbub.googlecode.com/svn/trunk/pubsubhubbub-core-0.3.html">PubSubHubbub protocol</a>
    </p>
    <p>Your request was not correct.</p>
  </body>
</html>
FAIL

  return $c->render(
    data   => $fail,
    status => 400  # bad request
  );
};


# Create challenge string
sub _challenge {
  state $l = scalar @CHALLENGE_CHARS;
  my $chal = '';
  for (1 .. $_[0] || 8) {
    $chal .= $CHALLENGE_CHARS[ int( rand( $l ) ) ];
  };
  return $chal;
};


1;


__END__


=pod

=head1 NAME

Mojolicious::Plugin::PubSubHubbub - Publish and Subscribe to PubSubHubbub


=head1 SYNOPSIS

  # Mojolicious
  $app->plugin(PubSubHubbub => {
    hub => 'https://hub.example.org/',
    pubsub_verify => sub {
      return 1;
    }
  });

  my $r = $app->routes;
  $r->route('/:user/callback_url')->pubsub;

  # Mojolicious::Lite
  plugin 'PubSubHubbub' => {
    hub => 'https://hub.example.org'
  };

  (any '/:user/callback_url')->pubsub;

  # In Controllers:
  # Publish feeds
  $c->pubsub_publish(
    'https://sojolicio.us/blog.atom',
    'https://sojolicio.us/activity.atom'
  );

  # Subscribe to a feed
  $c->pubsub_subscribe(
    topic => 'https://sojolicio.us/feed.atom',
    hub   => 'https://hub.sojolicio.us'
  );

  # Discover a resource
  my ($topic, $hub) = $c->pubsub_discover('http://sojolicio.us/');
  if ($topic && $hub) {
    $c->pubsub_subscribe( topic => $topic, hub   => $hub );
  };

  # Unsubscribe from a feed
  $c->pubsub_unsubscribe(
    topic => 'https://sojolicio.us/feed.atom',
    hub   => 'https://hub.sojolicio.us'
  );


=head1 DESCRIPTION

L<Mojolicious::Plugin::PubSubHubbub> is a plugin to publish and subscribe to
L<PubSubHubbub 0.3|http://pubsubhubbub.googlecode.com/svn/trunk/pubsubhubbub-core-0.3.html>
Webhooks.

The plugin currently supports the publisher and subscriber part of the protocol,
I<not> the hub part.

This plugin is data store agnostic.
Please use this plugin by applying hooks.


=head1 METHODS

=head2 register

  # Mojolicious
  $app->plugin(PubSubHubbub => {
    hub => 'https://hub.example.org/',
    lease_seconds => 100 * 24 * 60 * 60
  });

  # Mojolicious::Lite
  plugin 'PubSubHubbub' => {
    hub => 'https://hub.example.org/',
    lease_seconds => 100 * 24 * 60 * 60
  };

  # Or in your config file
  {
    PubSubHubbub => {
      hub => 'https://hub.example.org/',
      lease_seconds => 100 * 24 * 60 * 60
    }
  }


Called when registering the plugin.
Accepts the attributes mentioned as parameters.
All parameters can be set either on registration or
as part of the configuration file with the key C<PubSubHubbub>.


=head1 ATTRIBUTES

=head2 hub

  $ps->hub('http://pubsubhubbub.appspot.com/');
  my $hub = $ps->hub;

The preferred hub. Currently local hubs are not supported.
Establishes an L<endpoint|Mojolicious::Plugin::Util::Endpoint> called C<pubsub-hub>.

Defaults to L<pubsubhubbub.appspot.com|http://pubsubhubbub.appspot.com/>,
but this B<may change without warnings!>


=head2 lease_seconds

  my $seconds = $ps->lease_seconds;
  $ps->lease_seconds(100 * 24 * 60 * 60);

Seconds a subscription is valid by default before auto refresh
is enabled.

Defaults to 7 days.


=head1 SHORTCUTS

=head2 pubsub

  my $r = $app->routes;
  $r->route('/:user/callback_url')->pubsub;

Define the callback endpoint for your subscriptions.
Establishes an L<endpoint|Mojolicious::Plugin::Util::Endpoint>
called C<pubsub-callback>.


=head1 HELPERS

=head2 pubsub_discover

  # In Controllers
  my ($topic, $hub) = $c->pubsub_discover('http://sojolicio.us/');

Discover a topic feed and a hub based on a URI.

B<Note:> The heuristic implementation may change without warnings.


=head2 pubsub_publish

  # In Controllers
  $c->pubsub_publish(
    'my_feed',                       # named route
    '/feed.atom',                    # relative paths
    'https://sojolicio.us/feed.atom' # absolute URIs
  );

Publish a list of feeds in terms of a notification to the hub.
Supports named routes, relative paths and absolute URIs.


=head2 pubsub_subscribe

  # In Controllers
  $c->pubsub_subscribe(
    topic => 'https://sojolicio.us/feed.atom',
    hub   => 'https://hub.sojolicio.us' );
    lease_seconds => 123456
  );

Subscribe to a topic.

Relevant parameters are C<hub>,
C<lease_seconds>, C<secret>, C<verify_token>, and C<callback>.
Additional parameters are ignored but can be accessed in the hooks.
If no C<verify_token> is given, it is automatically generated.
If no C<callback> is given, the route callback is used.
If no C<lease_seconds> is given, the subscription won't
automatically terminate.
If a C<secret> is given, it must be unique for every C<callback>
and C<hub> combination to allow for bulk distribution.

The method returns a C<true> value on success and a C<false> value
if an error occured. If called in an array context, the
hub's response message body is returned additionally.


=head2 pubsub_unsubscribe

  # In Controllers
  $c->pubsub_unsubscribe(
    topic => 'https://sojolicio.us/feed.atom',
    hub   => 'https://hub.sojolicio.us'
  );

Unsubscribe from a topic.

Relevant parameters are C<hub>, C<secret>, and C<verify_token>.
Additional parameters are ignored but can be accessed in the hooks.

The method returns a C<true> value on success and a C<false> value
if an error occured. If called in an array context, the
hub's response message body is returned additionally.


=head1 CALLBACKS

=head2 pubsub_accept

  # Establish callback
  $mojo->callback(
    pubsub_accept => sub {
      my ($c, $type, $topics) = @_;

      # Filter topics
      my @new_topics = grep($_ !~ /catz/, @$topics);

      # Set secret
      my $secret     = 'z0idberg';

      # Set X-Hub-On-Behalf-Of value
      my $on_behalf  = 3;
      return (\@new_topics, $secret, $on_behalf);
    });

This callback is released, when content arrives at the
pubsub endpoint. The parameters passed to the callback
include the current controller object, the content type,
and an array reference of topics.

Expects an array reference of maybe filtered topics,
a secret if necessary, and the value of C<X-Hub-On-Behalf-Of>.
If the returned topic list is empty, the processing will stop.
If the callback is not established, the complete content will be
processed.

The callback can be established with the
L<callback|Mojolicious::Plugin::Util::Callback/callback>
helper or on registration.


=head2 pubsub_verify

  # Establish callback
  $mojo->callback(
    pubsub_verify => sub {
      my ($c, $param) = @_;

      # Topic is valid
      if ($param->{topic} =~ /catz/ &&
          $param->{verify_token} eq 'zoidberg') {
        return 1;
      };

      # Not verified
      return;
    });

This callback is released, when a verification is requested. The parameters
include the current controller object and the parameters
of the verification request as a hash reference.
If verification is granted, this callback must return a true value.

The callback can be established with the
L<callback|Mojolicious::Plugin::Util::Callback/callback>
helper or on registration.


=head1 HOOKS

=head2 on_pubsub_content

  $mojo->hook(
    on_pubsub_content => sub {
      my ($c, $type, $dom) = @_;

      if ($type eq 'atom') {
        $dom->find('entry')->each(
          print $_->at('title')->text, "\n";
        );
      };

      return;
    });

This hook is released, when desired (i.e., verified and optionally
filtered) content arrives.
The parameters include the current
controller object, the content type, and the - maybe topic
filtered - content as a L<Mojo::DOM> object.

B<Note:> The L<Mojo::DOM> object is canonicalized in a way that each
entry in the feed (either RSS or Atom) includes its topic in
C<source link[rel="self"]>.


=head2 before_pubsub_subscribe

  $mojo->hook(
    before_pubsub_subscribe => sub {
      my ($c, $params, $post) = @_;

      my $topic = $params->{topic};
      print "Start following $topic\n";

      return;
    });

This hook is released, before a subscription request is sent to a hub.
The parameters include the current controller object,
the parameters for subscription as a Hash reference and the C<POST>
string as a string ref.
This hook can be used to store subscription information and establish
a secret value.


=head2 after_pubsub_subscribe

  $mojo->hook(
    after_pubsub_subscribe => sub {
      my ($c, $params, $status, $body) = @_;
      if ($status !~ /^2/) {
        warn 'Error: ', $body;
      };

      return;
    });

This hook is released, after a subscription request is sent to a hub
and the response is processed.
The parameters include the current controller object,
the parameters for subscription as a Hash reference, the response status,
and the response body.
This hook can be used to deal with errors.


=head2 before_pubsub_unsubscribe

  $mojo->hook(
    before_pubsub_unsubscribe => sub {
      my ($c, $params, $post) = @_;

      my $topic = $params->{topic};
      print "Stop following $topic\n";

      return;
    });

This hook is released, before an unsubscription request is sent
to a hub.
The parameters include the current controller object,
the parameters for unsubscription as a Hash reference and the C<POST>
string as a string ref.
This hook can be used to store unsubscription information.


=head2 after_pubsub_unsubscribe

  $mojo->hook(
    after_pubsub_unsubscribe => sub {
      my ($c, $params, $status, $body) = @_;
      if ($status !~ /^2/) {
        warn 'Error: ', $body;
      };

      return;
    });

This hook is released, after an unsubscription request is sent to a hub
and the response is processed.
The parameters include the current controller object,
the parameters for unsubscription as a Hash reference, the response status,
and the response body.
This hook can be used to deal with errors.


=head1 DEPENDENCIES

L<Mojolicious>,
L<Mojolicious::Plugin::Util::Endpoint>,
L<Mojolicious::Plugin::Util::Callback>.


=head1 AVAILABILITY

  https://github.com/Akron/Mojolicious-Plugin-PubSubHubbub


=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011-2013, L<Nils Diewald|http://nils-diewald.de/>.

This program is free software, you can redistribute it
and/or modify it under the same terms as Perl.

=cut
