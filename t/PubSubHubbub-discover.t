use strict;
use warnings;

$|++;

use Test::Mojo;
use Test::More;
use Mojolicious::Lite;
use Mojo::ByteStream ('b');
use Mojo::Headers;
use lib '../lib';

use_ok('Mojolicious::Plugin::PubSubHubbub');

my $t = Test::Mojo->new;
my $app = $t->app;

$app->plugin('PubSubHubbub');

my $headers = Mojo::Headers->new;
$headers->parse(<<'LINKS');
Link: <http://example.com/TheBook/chapter2>; rel="previous";
         title="previous chapter"
Link: </>; rel="http://example.net/foo"
Link: </TheBook/chapter2>;
         rel="previous"; title*=UTF-8'de'letztes%20Kapitel,
         </TheBook/chapter4>;
         rel="next"; title*=UTF-8'de'n%c3%a4chstes%20Kapitel
Link: <http://example.org/>;
             rel="start http://example.net/relation/other"

LINKS

my @headers = $headers->header('link');

print $headers[0]->[0];


__END__

my @prev = Mojolicious::Plugin::PubSubHubbub::_discover_link($headers, 'previous');
is($prev[0]->[0], 'http://example.com/TheBook/chapter2', 'href');
is($prev[0]->[1], 'unknown', 'type');
is($prev[0]->[2], 'previous chapter', 'title');
is($prev[1]->[0], '/TheBook/chapter2', 'href');
is($prev[1]->[1], 'unknown', 'type');
ok(!$prev[1]->[2], 'title');

my ($topic, $hub) = $app->pubsub_discover('http://jessica-koppe.de/');

warn $topic;


done_testing;

__END__





