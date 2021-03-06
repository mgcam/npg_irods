
use strict;
use warnings;

# These paths are propagated to @INC in the build script. The 't/lib'
# directory is added because the Test::Class tests are there.
use lib qw(lib t/lib);

use WTSI::DNAP::Utilities::Build;

my $build = WTSI::DNAP::Utilities::Build->new
  (module_name        => 'npg_irods',
   dist_author        => 'NPG <npg@sanger.ac.uk>',
   dist_abstract      => 'NPG iRODS data/metadata loading and update tools',
   dist_version       => WTSI::DNAP::Utilities::Build->report_version,
   license            => 'gpl',
   configure_requires =>
   {
    'Module::Build'                 => ">= 0.4218"
   },
   build_requires =>
   {
    'File::Copy::Recursive'         => 0,
    'TAP::Harness'                  => '>= 3.30',
    'Test::Class'                   => '>= 0.41',
    'Test::Compile'                 => 0,
    'Test::HTTP::Server'            => 0,
    'Test::More'                    => '>= 0.98',
    'Test::Exception'               => '>= 0.32',
    'Test::Perl::Critic'            => '>= 1.02'
   },
   requires =>
   {
    'Carp'                          => '>= 1.20',
    'Data::Dump'                    => 0,
    'Log::Log4perl'                 => '>= 1.42',
    'List::AllUtils'                => '>= 0.09',
    'Moose'                         => '>= 2.1',
    'MooseX::Types'                 => '>= 0.45',
    'MooseX::StrictConstructor'     => 0,
    'Text::CSV'                     => '>= 1.33',
    'Try::Tiny'                     => '>= 0.12',
    'URI'                           => 0,
    'WTSI::DNAP::Utilities'         => '>= 0.5.1',   # perl-dnap-utilities
    'WTSI::NPG::iRODS'              => '>= 2.4.0',   # perl-irods-wrap
    'WTSI::DNAP::Warehouse::Schema' => '>= 1.8',     # ml_warehouse
    'st::api::lims'                 => '>= 85.1',    # npg_tracking
    'st::api::lims::ml_warehouse'   => '>= 38.0'     # npg_ml_warehouse
   },
   recommends =>
   {
    'npg_common::roles::software_location' => 0      # npg_seq_common
   }
  );

$build->create_build_script;

1;
