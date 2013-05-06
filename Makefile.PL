use strict;
use warnings;

use ExtUtils::MakeMaker;


WriteMakefile(
    NAME          => 'AnyEvent::STOMP::Client',
    AUTHOR        => 'Raphael Seebacher<raphael@seebachers.ch>',
    ABSTRACT_FROM => 'lib/AnyEvent/STOMP/Client.pm',
    VERSION_FROM  => 'lib/AnyEvent/STOMP/Client.pm',
    PREREQ_PM     => {
        AnyEvent => 7.04,
        Object::Event => 1.23,
    },
);
