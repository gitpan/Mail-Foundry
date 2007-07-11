use 5.008001;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'Mail::Foundry',
    VERSION_FROM      => 'lib/Mail/Foundry.pm', # finds $VERSION
    PREREQ_PM         => { LWP::UserAgent => 2.00,
                           URI::Escape    => 3.20,
			   HTML::Form     => 1.00, },
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/Mail/Foundry.pm', # retrieve abstract from module
       AUTHOR         => 'Scott Wiersdorf <scott@perlcode.org>') : ()),
);
