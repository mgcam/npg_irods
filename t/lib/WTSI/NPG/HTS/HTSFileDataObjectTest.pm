package WTSI::NPG::HTS::HTSFileDataObjectTest;

use strict;
use warnings;

use File::Spec;
use File::Temp;
use List::AllUtils qw(each_array);
use Log::Log4perl;
use Test::More tests => 76;

use base qw(Test::Class);

Log::Log4perl::init('./etc/log4perl_tests.conf');

BEGIN { use_ok('WTSI::NPG::HTS::HTSFileDataObject') }

use WTSI::DNAP::Warehouse::Schema;
use WTSI::NPG::HTS::HTSFileDataObject;
use WTSI::NPG::HTS::Samtools;
use WTSI::NPG::iRODS::Metadata;
use WTSI::NPG::iRODS;

{
  package TestDB;
  use Moose;

  with 'npg_testing::db';
}

my $fixture_counter = 0;
my $data_path = './t/data';
my $fixture_path = "$data_path/fixtures";

my $data_file0 = '3002_3#0';
my $data_file1 = '3002_3#1';

my $reference_file = 'test_ref.fa';
my $irods_tmp_coll;
my $samtools = `which samtools`;

my $have_admin_rights =
  system(qq{$WTSI::NPG::iRODS::IADMIN lu >/dev/null 2>&1}) == 0;

# Prefix for test iRODS data access groups
my $group_prefix = 'group_';
# Groups to be added to the test iRODS
my @irods_groups = map { $group_prefix . $_ } (10, 100, 244);
# Groups added to the test iRODS in fixture setup
my @groups_added;

my $pid = $$;

sub setup_fixture : Test(setup) {
  my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0);

  $irods_tmp_coll =
    $irods->add_collection("HTSFileDataObjectTest.$pid.$fixture_counter");
  $fixture_counter++;

  if ($have_admin_rights) {
    foreach my $group (@irods_groups) {
      if (not $irods->group_exists($group)) {
        push @groups_added, $irods->add_group($group);
      }
    }
  }

  if ($samtools) {
    foreach my $data_file ($data_file0, $data_file1) {
      WTSI::NPG::HTS::Samtools->new
          (arguments => ['view', '-C',
                         '-T', qq[$data_path/$reference_file],
                         '-o', qq[irods:$irods_tmp_coll/$data_file.cram]],
           path      => "$data_path/$data_file.sam")->run;

      WTSI::NPG::HTS::Samtools->new
          (arguments => ['view', '-b',
                         '-T', qq[$data_path/$reference_file],
                         '-o', qq[irods:$irods_tmp_coll/$data_file.bam]],
           path      => "$data_path/$data_file.sam")->run;

      if (@groups_added) {
        # Add some test group permissions
        foreach my $format (qw(bam cram)) {
          foreach my $group (qw(group_10 group_100)) {
            $irods->set_object_permissions
              ('read', $group, "$irods_tmp_coll/$data_file.$format");
          }
        }
      }
    }
  }
}

sub teardown_fixture : Test(teardown) {
  my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0);

  $irods->remove_collection($irods_tmp_coll);

  if ($have_admin_rights) {
    foreach my $group (@groups_added) {
      if ($irods->group_exists($group)) {
        $irods->remove_group($group);
      }
    }
  }
}

sub require : Test(1) {
  require_ok('WTSI::NPG::HTS::HTSFileDataObject');
}

my @example_paths =
  ('/seq/6345/6345_5',
   '/seq/6345/6345_5_phix',
   '/seq/6345/6345_5_phix#6',
   '/seq/6345/6345_5_nonhuman#6',
   '/seq/6345/6345_5#6',
   '/seq/6345/6345_5#6_phix');

sub id_run : Test(6) {
  my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0);

  foreach my $path (@example_paths) {
    my $full_path = $path . q[.cram];
    cmp_ok(WTSI::NPG::HTS::HTSFileDataObject->new($irods, $full_path)->id_run,
           '==', 6345, "$full_path id_run is correct");
  }
}

sub position : Test(12) {
  my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0);

  foreach my $format (qw(bam cram)) {
    foreach my $path (@example_paths) {
      my $full_path = $path . ".$format";
      cmp_ok(WTSI::NPG::HTS::HTSFileDataObject->new
             ($irods, $full_path)->position,
             '==', 5, "$full_path position is correct");
    }
  }
}

sub tag_index : Test(12) {
  my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0);

  foreach my $format (qw(bam cram)) {
    my @objs;
    foreach my $path (@example_paths) {
      push @objs, WTSI::NPG::HTS::HTSFileDataObject->new
        ($irods, $path . ".$format");
    }
    my @tag_indices = (undef, undef, 6, 6, 6, 6);

    my $iter = each_array(@objs, @tag_indices);
    while (my ($obj, $tag_index) = $iter->()) {
      my $full_path = $obj->str;
      # 2 * 6 tests
      if (defined $tag_index) {
        cmp_ok($obj->tag_index, '==', $tag_index,
               "$full_path tag_index is correct");
      }
      else {
        isnt(defined $obj->tag_index,
             "$full_path tag_index is correct");
      }
    }
  }
}

sub align_filter : Test(12) {
  my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0);

  foreach my $format (qw(bam cram)) {
    my @objs;
    foreach my $path (@example_paths) {
      push @objs, WTSI::NPG::HTS::HTSFileDataObject->new
        ($irods, $path . ".$format");
    }
    my @align_filters = (undef, 'phix', 'phix', 'nonhuman', undef, 'phix');

    my $iter = each_array(@objs, @align_filters);
    while (my ($obj, $filter) = $iter->()) {
      my $full_path = $obj->str;
      # 2 * 6 tests
      is($obj->align_filter, $filter, "$full_path align_filter is correct");
    }
  }
}

sub header : Test(8) {
 SKIP: {
    if (not $samtools) {
      skip 'samtools executable not on the PATH', 8;
    }

    my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0);

    foreach my $data_file ($data_file0, $data_file1) {
      foreach my $format (qw(bam cram)) {
        my $obj = WTSI::NPG::HTS::HTSFileDataObject->new
          (collection  => $irods_tmp_coll,
           data_object => "$data_file.$format",
           file_format => $format,
           id_run      => 1,
           irods       => $irods,
           position    => 1);

        # 2 * 2 * 1 tests
        ok($obj->header, "$format header can be read");

        # 2 * 2 * 1 tests
        cmp_ok(scalar @{$obj->header}, '==', 11,
               "Correct number of $format header lines") or
                 diag explain $obj->header;
      }
    }
  } # SKIP samtools
}

sub is_aligned : Test(4) {
 SKIP: {
    if (not $samtools) {
      skip 'samtools executable not on the PATH', 4;
    }

    my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0);

    foreach my $data_file ($data_file0, $data_file1) {
      foreach my $format (qw(bam cram)) {
        my $obj = WTSI::NPG::HTS::HTSFileDataObject->new
          (collection  => $irods_tmp_coll,
           data_object => "$data_file.$format",
           file_format => $format,
           id_run      => 1,
           irods       => $irods,
           position    => 1);

        # 2 * 2 * 1 tests
        ok($obj->is_aligned, "$format data are aligned");
      }
    }
  } # SKIP samtools
}

sub reference : Test(4) {
 SKIP: {
    if (not $samtools) {
      skip 'samtools executable not on the PATH', 4;
    }

    my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0);

    foreach my $data_file ($data_file0, $data_file1) {
      foreach my $format (qw(bam cram)) {
        my $obj = WTSI::NPG::HTS::HTSFileDataObject->new
          (collection  => $irods_tmp_coll,
           data_object => "$data_file.$format",
           file_format => $format,
           id_run      => 1,
           irods       => $irods,
           position    => 1);

        my $regex = qr{\./t\/data\/test_ref.fa}msx;
        my $filter = sub {
          my ($line) = @_;
          return $line =~ m{$regex}msx;
        };

        # 2 * 2 * 1 tests
        is($obj->reference($filter), './t/data/test_ref.fa',
           "$format reference is correct");
      }
    }
  } # SKIP samtools
}

sub update_secondary_metadata : Test(16) {
 SKIP: {
    if (not $samtools) {
      skip 'samtools executable not on the PATH', 16;
    }

    my $group_filter = sub {
      my ($group) = @_;
      if ($group =~ m{^$group_prefix}) {
        return 1
      }
      else {
        return 0;
      }
    };

    my $irods = WTSI::NPG::iRODS->new(strict_baton_version => 0,
                                      group_prefix         => $group_prefix,
                                      group_filter         => $group_filter);

    my $db_dir = File::Temp->newdir;
    my $db_file = File::Spec->catfile($db_dir, 'ml_warehouse.db');

    my $schema;
    # create_test_db produces warnings during expected use, which
    # appear mixed with test output in the terminal
    {
      local $SIG{__WARN__} = sub { };
      $schema = TestDB->new->create_test_db('WTSI::DNAP::Warehouse::Schema',
                                            './t/data/fixtures', $db_file);
    }

    my $ref_regex = qr{\./t\/data\/test_ref.fa}msx;
    my $ref_filter = sub {
      my ($line) = @_;
      return $line =~ m{$ref_regex}msx;
    };

    foreach my $data_file ($data_file0, $data_file1) {
      foreach my $format (qw(bam cram)) {
        my $obj = WTSI::NPG::HTS::HTSFileDataObject->new
          (collection  => $irods_tmp_coll,
           data_object => "$data_file.$format",
           irods       => $irods);

        my @groups_before = $obj->get_groups;

        my $with_spiked_control = 0;
        # 2 * 2 * 1 tests
        ok($obj->update_secondary_metadata($schema, $with_spiked_control,
                                           $ref_filter),
           'Updating secondary metadata, w/o spiked control');

        my @groups_after = $obj->get_groups;

        my $tag0_expected_meta =
          [{attribute => $ALIGNMENT,                value     => '1'},
           {attribute => $ID_RUN,                   value     => '3002'},
           {attribute => $POSITION,                 value     => '3'},
           {attribute => $LIBRARY_ID,               value     => '60186'},
           {attribute => $LIBRARY_ID,               value     => '60188'},
           {attribute => $LIBRARY_ID,               value     => '60190'},
           {attribute => $LIBRARY_ID,               value     => '60192'},
           {attribute => $LIBRARY_ID,               value     => '60194'},
           {attribute => $LIBRARY_ID,               value     => '60196'},
           {attribute => $LIBRARY_ID,               value     => '60198'},
           {attribute => $LIBRARY_ID,               value     => '60200'},
           {attribute => $LIBRARY_ID,               value     => '60202'},
           {attribute => $LIBRARY_ID,               value     => '60204'},
           {attribute => $LIBRARY_ID,               value     => '60206'},
           {attribute => $LIBRARY_ID,               value     => '60208'},
           {attribute => $REFERENCE,
            value     => './t/data/test_ref.fa'},
           {attribute => $SAMPLE_COMMON_NAME,
            value     => 'Streptococcus suis'},
           {attribute => $SAMPLE_CONSENT_WITHDRAWN, value     => '0'},
           {attribute => $SAMPLE_NAME,              value     => 'BM308'},
           {attribute => $SAMPLE_NAME,              value     => 'BM315'},
           {attribute => $SAMPLE_NAME,              value     => 'BM321'},
           {attribute => $SAMPLE_NAME,              value     => 'BM329'},
           {attribute => $SAMPLE_NAME,              value     => 'BM334'},
           {attribute => $SAMPLE_NAME,              value     => 'BM345'},
           {attribute => $SAMPLE_NAME,              value     => 'BM346'},
           {attribute => $SAMPLE_NAME,              value     => 'BM357'},
           {attribute => $SAMPLE_NAME,              value     => 'BM358'},
           {attribute => $SAMPLE_NAME,              value     => 'BM362'},
           {attribute => $SAMPLE_NAME,              value     => 'BM366'},
           {attribute => $SAMPLE_NAME,              value     => 'BM373'},
           {attribute => $STUDY_ACCESSION_NUMBER,   value     => 'ERP000893'},
           {attribute => $STUDY_ID,                 value     => '244'},
           {attribute => $STUDY_NAME,
            value     =>
            'Discovery of sequence diversity in Streptococcus suis (Vietnam)'},
           {attribute => $STUDY_TITLE,
            value     =>
            'Discovery of sequence diversity in Streptococcus suis (Vietnam)'},
           {attribute => $TAG_INDEX,                value     => '0'}];

        my $tag1_expected_meta =
          [{attribute => $ALIGNMENT,                value     => '1'},
           {attribute => $ID_RUN,                   value     => '3002'},
           {attribute => $POSITION,                 value     => '3'},
           {attribute => $LIBRARY_ID,               value     => '60186'},
           {attribute => $QC_STATE,                 value     => '0'},
           {attribute => $REFERENCE,
            value     => './t/data/test_ref.fa'},
           {attribute => $SAMPLE_COMMON_NAME,
            value     => 'Streptococcus suis'},
           {attribute => $SAMPLE_CONSENT_WITHDRAWN, value     => '0'},
           {attribute => $SAMPLE_NAME,              value     => 'BM308'},
           {attribute => $STUDY_ACCESSION_NUMBER,   value     => 'ERP000893'},
           {attribute => $STUDY_ID,                 value     => '244'},
           {attribute => $STUDY_NAME,
            value     =>
            'Discovery of sequence diversity in Streptococcus suis (Vietnam)'},
           {attribute => $STUDY_TITLE,
            value     =>
            'Discovery of sequence diversity in Streptococcus suis (Vietnam)'},
           {attribute => $TAG_INDEX,                value     => '1'}];

        my $meta = [grep { $_->{attribute} !~ m{_history$} }
                    @{$obj->metadata}];

        # 2 * 2 * 1 tests
        if ($obj->tag_index == 0) {
          is_deeply($meta, $tag0_expected_meta,
                    'Secondary metadata updated correctly, tag 0')
            or diag explain $meta;
        }
        else {
          is_deeply($meta, $tag1_expected_meta,
                    'Secondary metadata updated correctly, tag 1')
            or diag explain $meta;
        }

      SKIP: {
          if (not @groups_added) {
            skip 'iRODS groups were not added', 2;
          }
          else {
            my $expected_groups_before = ['group_10', 'group_100'];
            # 2 * 2 * 1 tests
            is_deeply(\@groups_before, $expected_groups_before,
                      'Groups before update') or diag explain \@groups_before;

            my $expected_groups_after = ['group_244'];
            # 2 * 2 * 1 tests
            is_deeply(\@groups_after, $expected_groups_after,
                      'Groups after update') or diag explain \@groups_after;
          }
        }
      } # SKIP groups_added
    }
 } # SKIP samtools
}

1;
