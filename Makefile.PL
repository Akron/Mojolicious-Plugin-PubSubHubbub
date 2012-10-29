#!/usr/bin/env perl
use 5.010001;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
  VERSION_FROM => 'lib/Mojolicious/Plugin/PubSubHubbub.pm',
  NAME         => 'Mojolicious::Plugin::PubSubHubbub',
  AUTHOR       => 'Nils Diewald',
  PREREQ_PM => {
    'Mojolicious' => 3.43,
    'Test::More' => 0
  },
  LICENSE      => 'perl',
  META_MERGE   => {
    requires  => {perl => '5.010001'},
    resources => {
      license     => 'http://www.opensource.org/licenses/artistic-license-2.0',
      repository  => 'https://github.com/Akron/Mojolicious-Plugin-PubSubHubbub'
    }
  },
  test => {TESTS => 't/*.t t/*/*.t t/*/*/*.t t/*/*/*/*.t'}
);
