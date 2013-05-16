use strict;
use warnings;

use ExtUtils::MakeMaker;


WriteMakefile(
    NAME          => 'AnyEvent::STOMP::Client',
    AUTHOR        => 'Raphael Seebacher <raphael@seebachers.ch>',
    LICENSE       => 'perl',
    ABSTRACT      => 'An event-based non-blocking STOMP 1.2 client based on AnyEvent and Object::Event.',
    VERSION_FROM  => 'lib/AnyEvent/STOMP/Client.pm',
    PREREQ_PM     => {
        'AnyEvent'      => 7.04,
        'Object::Event' => 1.23,
    },
);
