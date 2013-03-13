use strict;
use warnings;

$|++;

use Test::Mojo;
use Test::More;
use Mojolicious::Lite;
use Mojo::ByteStream ('b');
use lib '../lib';

use_ok('Mojolicious::Plugin::PubSubHubbub');

ok();
