sub hub {
    my $self = shift;
    my $c = shift;
    my $param = $c->param;
    my %hub_param;

    foreach my $key (map(s/^hub\.//, grep('hub.', keys %$param))) {
	$hub_param{ $key } = $param->{ 'hub.' . $key };
    };

    my $mode = $hub_param{mode};

    my $ok = 0;

    # Subscribe to feed
    if ($mode eq 'subscribe') {
	if (exists $hub_param{ callback } &&
	    exists $hub_param{ topic } &&
	    ) {

	    # todo: topic: delete fragments.
            # from Google's hub (see subfeedr)
	    # my %valid_ports = map { $_ => 1 } (80, 443, 4443, 8080 .. 8089, 8188, 8440, 8990);	    

	    # Delete Whitespace from secret!
	    if (exists $hub_param{secret}) {
		trim($hub_param{secret});
	    };

	    $self->app->run_hook( 'on_pubsub_hub_subscription' => 
				  $self,
				  $c,
				  \%hub_param,
				  \$ok );
	};

	if ($$ok) {
	    my $verify_token = $param_hub{verify_token};


	    # VERIFY REQUEST
	    my $verified = 0;
	    my $challenge = _generate_challenge(4);

	    # Verification mode -- only 'sync' supported
#	    if ($hub_param{verify} eq 'sync' ||
#		$hub_param{verify} eq 'async') {

	    # Create verification request
	    my $verify_url = Mojo::URL->new($param_hub{callback});
	    my $params = $verify_url->params;
	    $params->append(
		'hub.mode'      => $param_hub{mode},
		'hub.topic'     => $param_hub{topic},
		'hub.challenge' => $challenge
		);

	    # Append 'verify_token' if existing
	    for ('verify_token') {
		$param->append('hub.'.$_ => $param_hub{$_})
		if exists $param_hub{$_};
	    };

	    # Append 'lease_seconds', which maybe is unset
	    for ('lease_seconds') {
		$param->append('hub.'.$_ =>
			       $param_hub{$_} || $self->lease_seconds );
	    };
	    
	    # Start request
	    my $ua = Mojo::UserAgent->new(max_redirects => 3)
	    my $get = $ua->get($verify_url->abs);
	    
	    if ($get->res->is_status_class(200)) {
		if ($get->res->body eq $challenge) {
		    # Verified!
		    $verified = 1;
		};
	    } elsif ($get->res->status == 404) {
		# definite fail
	    }

# Todo - wenn async kann ein fail nur temporär sein und sollte retried werden


#	    }

	    if ($hub_param{secret}) {
		# todo
	    };

	    # Request verified
	    if ($verified) {
		return $c->render(status => 204);
	    }

	    # Request not yet verified
	    elsif ($hub_param{verify} eq 'async') {
		return $c->render(status => 202)
	    };

	}

	# Not okay
	else {
	    $c->render(status => 404,
		       data   => 'This feed is not published '.
		                 'by this hub.' );
	};


    } elsif ($mode eq 'unsubscribe') {
    } elsif ($mode eq 'publish') {
    } else {
	# unknown mode
    };
};

# Verify a changed subscription or automatically refresh
sub hub_verify {
};

sub hub_publish {
    my $self = shift;
    my $c = shift;
    my $feed_url = shift;
    my $param = ref($_[0]) ? shift(@_) : {};
    my $payload = shift;

    # Subscriber structure:
    #   [{secret => 'ggfhgfhg'?, callback => 'http...'}*]

    my $subscribers = [];
    $self->app->run_hook('on_pubsub_hub_publishing' =>
			 $self,
			 $c,
			 $feed_url,
			 $subscribers);
    
    $param->{'Content-Type'} ||= 'application/atom+xml';

    my $ua = Mojo::UserAgent->new(max_redirects => 3)

    foreach my $subscriber (@$subscribers) {
	delete $param->{'X-Hub-Signature'};

	# Signature needed
	if (exists $subscriber->{secret}) {
	    # Todo: Check if this is 40char hexadecimal!
	    $param->{'X-Hub-Signature'} =
		'sha1=' . b($payload)->hmac_sha1_sum($subscriber->{secret});
	}

	my $response = $ua->post($subscriber->{callback} =>
				 $param =>
				 $payload);

	if ($response->res->is_status_class(200)) {
	    # ready
	} elsif ($response->res->code == 404) {
	    # fail
	} else {
	    # retry
	};
	
    };
};


sub _generate_challenge {
    my $length = shift;

    my $challenge = '';

    my $c_l = @challenge_chars - 1;
    foreach (0 .. $length) {
	$challenge .= $challenge_chars[int(rand($c_l))];
    };
    return $challenge;
};

1;

=pod

=head1 NAME

Mojolicious::Plugin::PubSubHubbub

=cut


my $ua = Mojo::UserAgent->new(max_redirects => 3);

foreach my $subscriber (@$subscribers) {
  delete $param->{'X-Hub-Signature'};

  # Signature needed
  if (exists $subscriber->{secret}) {
    # Todo: Check if this is 40char hexadecimal!
    $param->{'X-Hub-Signature'} =
      'sha1=' . b($payload)->hmac_sha1_sum($subscriber->{secret});
  }

  $ua->post(
    $subscriber->{callback} =>
      $param =>
	$payload => sub {
	  my ($ua, $tx) = @_;

	  my $host = $tx->req->host;

	  if ($tx->res->is_status_class(200)) {
	    # ready
	  } elsif ($tx->res->code == 404) {
	    # fail
	  } else {
	    # retry
	  };
	});

	
    };
