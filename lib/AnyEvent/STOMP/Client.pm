package AnyEvent::STOMP::Client;


use strict;
use warnings;

use parent 'Object::Event';

use Carp;
use AnyEvent;
use AnyEvent::Handle;
use List::Util 'max';


our $VERSION = '0.02';


my $TIMEOUT_MARGIN = 1000;
my $EOL = chr(10);
my $NULL = chr(0);


sub connect {
    my $class = shift;
    my $self = $class->SUPER::new;

    $self->{connected} = 0;
    $self->{host} = shift || 'localhost';
    $self->{port} = shift || 61613;

    my $additional_headers = shift || {};
    my $connect_headers = {
        'accept-version' => '1.2',
        'host' => $self->{host},
        'heart-beat' => '0,0'
    };

    if (defined $additional_headers->{'heart-beat'}) {
        $connect_headers->{'heart-beat'} = $additional_headers->{'heart-beat'};
    }
    $self->{heartbeat}{config}{client} = $connect_headers->{'heart-beat'};


    if (defined $additional_headers->{'login'}
        and defined $additional_headers->{'passcode'}
    ) {
        $connect_headers->{'login'} = $additional_headers->{'login'};
        $connect_headers->{'passcode'} = $additional_headers->{'passcode'};
    }

    $self->{handle} = AnyEvent::Handle->new(
        connect => [$self->{host}, $self->{port}],
        keep_alive => 1,
        on_connect => sub {
            $self->send_frame('CONNECT', $connect_headers);
        },
        on_connect_error => sub {
            my ($handle, $message) = @_;
            $handle->destroy;
            $self->{connected} = 0;
            $self->event('DISCONNECTED');
        },
        on_error => sub {
            my ($handle, $message) = @_;
            $handle->destroy;
            $self->{connected} = 0;
            $self->event('DISCONNECTED');
        },
        on_read => sub {
            $self->read_frame;
        },
    );

    return bless $self, $class;
}

sub disconnect {
    shift->send_frame('DISCONNECT', {receipt => int(rand(1000)),});
}

sub DESTROY {
    my $self = shift;
    $self->disconnect if $self->is_connected;
}

sub is_connected {
    return shift->{connected};
}

sub set_heartbeat_intervals {
    my $self = shift;
    $self->{heartbeat}{config}{server} = shift;

    my ($cx, $cy) = split ',', $self->{heartbeat}{config}{client};
    my ($sx, $sy) = split ',', $self->{heartbeat}{config}{server};

    if ($cx == 0 or $sy == 0) {
        $self->{heartbeat}{interval}{client} = 0;
    }
    else {
        $self->{heartbeat}{interval}{client} = max($cx, $sy);
    }

    if ($sx == 0 or $cy == 0) {
        $self->{heartbeat}{interval}{server} = 0;
    }
    else {
        $self->{heartbeat}{interval}{server} = max($sx, $cy);
    }
}

sub reset_client_heartbeat_timer {
    my $self = shift;
    my $interval = $self->{heartbeat}{interval}{client};

    unless (defined $interval and $interval > 0) {
        return;
    }

    $self->{heartbeat}{timer}{client} = AnyEvent->timer(
        after => ($interval/1000),
        cb => sub {
            $self->send_heartbeat;
        }
    );
}

sub reset_server_heartbeat_timer {
    my $self = shift;
    my $interval = $self->{heartbeat}{interval}{server};

    unless (defined $interval and $interval > 0) {
        return;
    }

    $self->{heartbeat}{timer}{server} = AnyEvent->timer(
        after => ($interval/1000+$TIMEOUT_MARGIN),
        cb => sub {
            $self->{connected} = 0;
            $self->event('DISCONNECTED');
        }
    );
}

sub subscribe {
    my $self = shift;
    my $destination = shift;
    my $ack_mode = shift || 'auto';
    my $additional_headers = shift || {};

    unless ($ack_mode =~ m/(?:auto|client|client-individual)/) {
        croak "Invalid acknowledgement mode '$ack_mode'. "
            ."Valid modes are 'auto', 'client' and 'client-individual'."
    }
    unless ($self->is_destination_valid($destination)) {
        croak "Would you mind supplying me with a valid destination?";
    }

    if (defined $self->{subscriptions}{$destination}) {
        carp "You already subscribed to '$destination'.";

        if ($self->handles('SUBSCRIBED')) {
            $self->event('SUBSCRIBED', $destination);
        }
    }
    else {
        my $subscription_id = shift || int(rand(1000));
        $self->{subscriptions}{$destination} = $subscription_id;

        my $header = {
            destination => $destination,
            id => $subscription_id,
            ack => $ack_mode, 
            %$additional_headers,
        };

        if ($self->handles('SUBSCRIBED')) {
            unless (defined $header->{receipt}) {
                $header->{receipt} = int(rand(1000));
            }

            $self->on_receipt(
                sub {
                    my ($self, $receipt_header) = @_;
                    if ($receipt_header->{'receipt-id'} == $header->{receipt}) {
                        $self->event('SUBSCRIBED', $header->{destination});
                        $self->unreg_me;
                    }
                }
            );
        }

        $self->send_frame('SUBSCRIBE', $header);
    }
}

sub unsubscribe {
    my $self = shift;
    my $destination = shift;
    my $additional_headers = shift || {};

    unless ($self->is_destination_valid($destination)) {
        croak "Would you mind supplying me with a valid destination?";
    }
    unless ($self->{subscriptions}{$destination}) {
        croak "You've never subscribed to '$destination', have you?";
    }

    my $header = {
        id => $self->{subscriptions}{$destination},
        %$additional_headers,
    };

    if ($self->handles('UNSUBSCRIBED')) {
        $header->{receipt} = int(rand(1000)) unless defined $header->{receipt};

        $self->on_receipt(
            sub {
                my ($self, $receipt_header) = @_;
                if ($receipt_header->{'receipt-id'} == $header->{receipt}) {
                    $self->event('UNSUBSCRIBED', $destination);
                    $self->unreg_me;
                }
            }
        );
    }

    $self->send_frame('UNSUBSCRIBE', $header);
    $self->{subscriptions}{$destination} = undef;
}

sub is_destination_valid {
    my ($self, $destination) = @_;
    return ($destination =~ m/^\/(?:queue|topic)\/.+$/);
}

sub header_hash2string {
    my $header_hashref = shift;
    return join($EOL, map { "$_:$header_hashref->{$_}" } keys %$header_hashref);
}

sub header_string2hash {
    my $header_string = shift;
    my $result_hashref = {};

    foreach (split /\n/, $header_string) {
        if (m/([^\r\n:]+):([^\r\n:]*)/) {
            # add header decoding
            # Repeated Header Entries: Do not replace if it already exists
            $result_hashref->{$1} = $2 unless defined $result_hashref->{$1};
        }
    }
    
    return $result_hashref;
}

sub encode_header {
    my $header_hashref = shift;

    my $ESCAPE_MAP = {
        chr(92) => '\\\\',
        chr(13) => '\\r',
        chr(10) => '\\n',
        chr(58) => '\c',
    };
    my $ESCAPE_KEYS = '['.join('', map(sprintf('\\x%02x', ord($_)), keys(%$ESCAPE_MAP))).']';

    my $result_hashref;

    while (my ($k, $v) = each(%$header_hashref)) {
        $v =~ s/($ESCAPE_KEYS)/$ESCAPE_MAP->{$1}/ego;
        $k =~ s/($ESCAPE_KEYS)/$ESCAPE_MAP->{$1}/ego;
        $result_hashref->{$k} = $v;
    }

    return $result_hashref;
}

sub decode_header {
    my $header_hashref = shift;
    # treat escape sequences like \t as fatal error

    return $header_hashref;
}

sub send_frame {
    my ($self, $command, $header_hashref, $body) = @_;

    utf8::encode($command);

    my $header;
    if ($command eq 'CONNECT') {
        $header = header_hash2string($header_hashref);
    }
    else {
        $header = header_hash2string(encode_header($header_hashref));
    }
    utf8::encode($header);

    my $frame;
    if ($command eq 'SEND') {
        $frame = $command.$EOL.$header.$EOL.$EOL.$body.$NULL;
    }
    else {
        $frame = $command.$EOL.$header.$EOL.$EOL.$NULL;
    }

    $self->event('SEND_FRAME', $frame);
    $self->{handle}->push_write($frame);
    $self->reset_client_heartbeat_timer;
}

sub ack {
    my ($self, $ack_id, $transaction) = @_;

    unless ($ack_id) {
        croak "I do really need the message's ack header to ACK it.";
    }
    
    my $header = {id => $ack_id,};
    $header->{transaction} = $transaction if (defined $transaction);

    $self->send_frame('ACK', $header);
}

sub nack {
    my ($self, $ack_id, $transaction) = @_;

    unless ($ack_id) {
        croak "I do really need the message's ack header to NACK it.";
    }
    
    my $header = {id => $ack_id,};
    $header->{transaction} = $transaction if (defined $transaction);

    $self->send_frame('NACK', $header);
}

sub send_heartbeat {
    my $self = shift;
    $self->{handle}->push_write($EOL);
    $self->reset_client_heartbeat_timer;
}

sub send {
    my ($self, $destination, $headers, $body) = @_;

    if ($self->is_destination_valid($destination)) {
        $headers->{destination} = $destination;
    }
    else {
        croak "Would you mind supplying me with a valid destination?";
    }

    unless (defined $headers->{'content-length'}) {
        $headers->{'content-length'} = length $body || 0;
    }

    unless (defined $headers->{'content-type'}) {
        carp "It is strongly recommended to set the 'content-type' header.";
    }

    $self->send_frame('SEND', $headers, $body);
}

sub read_frame {
    my $self = shift;
    $self->{handle}->unshift_read(
        line => sub {
            my ($handle, $command, $eol) = @_;

            $self->reset_server_heartbeat_timer;

            unless ($command =~ /CONNECTED|MESSAGE|RECEIPT|ERROR/) {
                return;
            }

            $self->{handle}->unshift_read(
                regex => qr<\r?\n\r?\n>,
                cb => sub {
                    my ($handle, $header_string) = @_;
                    my $header_hashref = header_string2hash($header_string);
                    my $args;

                    if ($command =~ m/MESSAGE|ERROR/) {
                        if (defined $header_hashref->{'content-length'}) {
                            $args->{chunk} = $header_hashref->{'content-length'};
                        }
                        else {
                            $args->{regex} = qr<[^\000]*\000>;
                        }

                        $self->{handle}->unshift_read(
                            %$args,
                            cb => sub {
                                my ($handle, $body) = @_;
                                $self->event('READ_FRAME', $command, $header_hashref, $body);
                                $self->event($command, $header_hashref, $body);

                                if (defined $header_hashref->{subscription}) {
                                    $self->event(
                                        $command.'-'.$header_hashref->{subscription},
                                        $header_hashref,
                                        $body
                                    );
                                }
                            }
                        );
                    }
                    else {
                        if ($command eq 'CONNECTED') {
                            $self->{connected} = 1;
                            $self->{session} = $header_hashref->{session};
                            $self->{version} = $header_hashref->{version};
                            $self->{server} = $header_hashref->{server};

                            $self->set_heartbeat_intervals($header_hashref->{'heart-beat'});
                        }

                        $self->event('READ_FRAME', $command, $header_hashref);
                        $self->event($command, $header_hashref);
                    }
                },
            );
        },
    );
}

sub on_send_frame {
    shift->reg_cb('SEND_FRAME', shift);
}

sub on_read_frame {
    shift->reg_cb('READ_FRAME', shift);
}

sub on_connected {
    shift->reg_cb('CONNECTED', shift);
}

sub on_disconnected {
    shift->reg_cb('DISCONNECTED', shift);
}

sub on_message {
    my ($self, $cb, $destination) = @_;

    unless (not defined $destination or $self->is_destination_valid($destination)) {
        croak "Would you mind supplying me with a valid destination?";
    }

    if (defined $destination and defined $self->{subscriptions}{$destination}) {
        $self->reg_cb('MESSAGE-'.$self->{subscriptions}{$destination}, $cb);
    }
    else {
        $self->reg_cb('MESSAGE', $cb);
    }
}

sub on_receipt {
    shift->reg_cb('RECEIPT', shift);
}

sub on_error {
    shift->reg_cb('ERROR', shift);
}

sub on_subscribed {
    shift->reg_cb('SUBSCRIBED', shift);
}

sub on_unsubscribed {
    shift->reg_cb('UNSUBSCRIBED', shift);
}

1;

__END__

=head1 NAME

AnyEvent::STOMP::Client - Perl extension for blah blah blah

=head1 SYNOPSIS

  use AnyEvent::STOMP::Client;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for AnyEvent::STOMP::Client, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.

=head2 EXPORT

None by default.



=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Raphael Seebacher, E<lt>raphael@seebachers.chE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Raphael Seebacher

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.


=cut
