#!/usr/bin/perl
################################################################################ 
#
# Basic Example of AnyEvent::STOMP::Client
#
# Written by Raphael Seebacher raphael@seebachers.ch
#
################################################################################

use lib '../lib';
use AnyEvent::STOMP::Client;

my $stomp_client = AnyEvent::STOMP::Client->connect();

$stomp_client->on_connected(
    sub {
        my $self = shift;

        $self->subscribe('/queue/test-destination', 'client');

        $self->send(
            '/queue/test-destination',
            {'content-type' => 'text/plain',},
            "Hello World!"
        );

        $self->disconnect;
    }
);

$stomp_client->on_message(
    sub {
        my ($self, $header, $body) = @_;
        print "$body\n";
    }
);

AnyEvent->condvar->recv;
