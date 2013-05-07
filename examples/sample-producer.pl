#!/usr/bin/perl
################################################################################ 
#
# Sample STOMP Message Producer using AnyEvent::STOMP::Client
#
# Written by Raphael Seebacher raphael@seebachers.ch
#
################################################################################

use lib '../lib';

use AnyEvent;
use AnyEvent::STOMP::Client;


my $cv = AnyEvent->condvar;
my $stomp_client = AnyEvent::STOMP::Client->connect();

$stomp_client->on_connected(
    sub {
        my $self = shift;
        print "Connection established!\n";

        $self->send(
            '/queue/test-destination',
            {'persistent' => 'true', 'content-type' => 'text/plain',},
            "Hello World!"
        );

        $self->disconnect;
    }
);

$stomp_client->on_disconnected(sub { $cv->send; });

$cv->recv;
