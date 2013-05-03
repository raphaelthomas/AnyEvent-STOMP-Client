package AnyEvent::STOMP::Client;


use strict;
use warnings;

use AnyEvent;
use AnyEvent::Handle;
use parent 'Object::Event';


our $VERSION = 0.01;


# Optionally prepend chr(13) for Windows-like line endings.
my $EOL = chr(10);
my $NULL = chr(0);


sub connect {
    my $class = shift;
    my $self = $class->SUPER::new;

    $self->{host} = shift;
    $self->{port} = shift || 61613;
    $self->{'heart-beat'} = shift || '0,0';

    $self->{handle} = AnyEvent::Handle->new(
        connect => [$self->{host}, $self->{port}],
        keep_alive => 1,
        on_connect => sub {
            $self->send_frame('CONNECT', {
                'accept-version' => '1.2',
                'host' => $self->{host},
                'heart-beat' => $self->{'heart-beat'},
                # add login, passcode headers
            });
            $self->receive_frame_connected();
        },
        on_connect_error => sub {
            my ($handle, $message) = @_;
            print "ERROR: $message.\n";
            $handle->destroy;
        },
        on_error => sub {
            my ($handle, $message) = @_;
            print "ERROR: $message.\n";
            $handle->destroy;
        },
        on_read => sub {
            $self->receive_frame;
        },
     );

    return bless $self, $class;
}

sub DESTROY {
    # shift->send_frame('DISCONNECT', {receipt => 9999,});
}

sub subscribe {
    my $self = shift;
    my $destination = shift;

    $self->send_frame('SUBSCRIBE', {destination => $destination, id => 0, ack => 'client',}, undef);
}

sub get_header_string {
    my $header_hashref = shift;
    return join($EOL, map { "$_:$header_hashref->{$_}" } keys %$header_hashref);
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
    # treat escape sequences like \t as fatal error
}

sub send_frame {
    my ($self, $command, $header_hashref, $body) = @_;

    my $header;
    if ($command eq 'CONNECT') {
        # do not escape header in the connect frame to ensure backwards
        # compatibility with STOMP v1.0
        $header = get_header_string($header_hashref);
    }
    else {
        $header = get_header_string(encode_header($header_hashref));
    }

    my $frame;
    if ($command eq 'SEND') {
        $frame = $command.$EOL.$header.$EOL.$EOL.$body.$NULL;
    }
    else {
        $frame = $command.$EOL.$header.$EOL.$EOL.$NULL;
    }

    $self->event('SEND_FRAME', $frame);
    $self->{handle}->push_write($frame);
}

sub send {
    my $self = shift;
    my ($destination, $headers, $body) = @_;

    unless (defined $headers->{'content-length'}) {
        $headers->{'content-length'} = length $body || 0;
    }
    $headers->{destination} = $destination;

    $self->send_frame('SEND', $headers, $body);
}

sub receive_frame {
    my $self = shift;

    # split it up into COMMAND, HEADER and BODY.
    $self->event('RECEIVE_FRAME', $self->{handle}->rbuf);
    $self->{handle}->rbuf = "";
}

sub receive_frame_connected {
    my $self = shift;

    $self->{handle}->unshift_read(
        regex => qr<\r?\n\r?\n>,
        cb => sub {
            my ($handle, $data) = @_;
            $self->event('RECEIVE_FRAME', $data);
            $self->event('CONNECTED');
        },
    );
}

sub on_connected {
    my $self = shift;
    my $cb = shift;

    $self->reg_cb('CONNECTED', $cb);
}

sub on_receive_frame {
    my $self = shift;
    my $cb = shift;

    $self->reg_cb('RECEIVE_FRAME', $cb);
}

sub on_send_frame {
    my $self = shift;
    my $cb = shift;

    $self->reg_cb('SEND_FRAME', $cb);
}

1;
