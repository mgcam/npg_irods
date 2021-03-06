package WTSI::NPG::HTS::Publisher;

use namespace::autoclean;
use Data::Dump qw[pp];
use DateTime;
use English qw[-no_match_vars];
use File::Spec::Functions qw[catdir catfile splitdir splitpath];
use File::stat;
use List::AllUtils qw[any];
use Moose;
use Try::Tiny;

use WTSI::NPG::iRODS::Collection;
use WTSI::NPG::iRODS::DataObject;
use WTSI::NPG::iRODS;

our $VERSION = '';

with qw[
         WTSI::DNAP::Utilities::Loggable
         WTSI::NPG::Accountable
         WTSI::NPG::HTS::Annotator
       ];

has 'irods' =>
  (is            => 'ro',
   isa           => 'WTSI::NPG::iRODS',
   required      => 1,
   default       => sub { return WTSI::NPG::iRODS->new },
   documentation => 'The iRODS connection handle');

has 'checksum_cache_threshold' =>
  (is            => 'ro',
   isa           => 'Int',
   required      => 1,
   default       => 2048,
   documentation => 'The size above which file checksums will be cached');

has 'require_checksum_cache' =>
  (is            => 'ro',
   isa           => 'ArrayRef[Str]',
   required      => 1,
   default       => sub { return [qw[bam cram]] },
   documentation => 'A list of file suffixes for which MD5 cache files ' .
                    'must be provided and will not be created on the fly');

has 'checksum_cache_time_delta' =>
  (is            => 'rw',
   isa           => 'Int',
   required      => 1,
   default       => 60,
   documentation => 'Time delta in seconds for checksum cache files to be ' .
                    'considered stale. If a data file is newer than its '   .
                    'cache by more than this number of seconds, the cache ' .
                    'is stale');

sub BUILD {
  my ($self) = @_;

  $self->irods->logger($self->logger);
  return;
}

=head2 publish

  Arg [1]    : Path to local file for directory, Str.
  Arg [2]    : Path to destination in iRODS, Str.
  Arg [3]    : Custom metadata AVUs to add, ArrayRef[HashRef].
  Arg [4]    : Timestamp to use in metadata, DateTime. Optional, defaults
               to current time.

  Example    : my $path = $pub->publish('./local/file.txt',
                                        '/zone/path/file.txt',
                                        [{attribute => 'x',
                                          value     => 'y'}])
  Description: Publish a local file or directory to iRODS, detecting which
               has been passed as an argument and then delegating to
               'publish_file' or 'publish_directory' as appropriate.
  Returntype : Str

=cut

sub publish {
  my ($self, $local_path, $remote_path, $metadata, $timestamp) = @_;

  my $published;
  if (-f $local_path) {
    $published = $self->publish_file($local_path, $remote_path, $metadata,
                                     $timestamp);
  }
  elsif (-d $local_path) {
    $published = $self->publish_directory($local_path, $remote_path, $metadata,
                                          $timestamp);
  }
  else {
    $self->logconfess('The local_path argument as neither a file nor a ',
                      'directory: ', "'$local_path'");
  }

  return $published;
}

=head2 publish_file

  Arg [1]    : Path to local file, Str.
  Arg [2]    : Path to destination in iRODS, Str.
  Arg [3]    : Custom metadata AVUs to add, ArrayRef[HashRef].
  Arg [4]    : Timestamp to use in metadata, DateTime. Optional, defaults
               to current time.

  Example    : my $path = $pub->publish_file('./local/file.txt',
                                             '/zone/path/file.txt',
                                             [{attribute => 'x',
                                               value     => 'y'}])
  Description: Publish a local file to iRODS, create and/or supersede
               metadata (both default and custom) and update permissions,
               returning the absolute path of the published data object.

               If the target path does not exist in iRODS the file will
               be transferred. Default creation metadata will be added and
               custom metadata will be added.

               If the target path exists in iRODS, the checksum of the
               local file will be compared with the cached checksum in
               iRODS. If the checksums match, the local file will not
               be uploaded. Default modification metadata will be added
               and custom metadata will be superseded.

               In both cases, permissions will be updated.
  Returntype : Str

=cut

sub publish_file {
  my ($self, $local_path, $remote_path, $metadata, $timestamp) = @_;

  $self->_check_path_args($local_path, $remote_path);
  -f $local_path or
    $self->logconfess("The local_path argument '$local_path' was not a file");

  if (defined $metadata and ref $metadata ne 'ARRAY') {
    $self->logconfess('The metadata argument must be an ArrayRef');
  }
  if (not defined $timestamp) {
    $timestamp = DateTime->now;
  }

  my $path;
  if ($self->irods->is_collection($remote_path)) {
    $self->info("Remote path '$remote_path' is a collection");

    my ($loc_vol, $dir, $file) = splitpath($local_path);
    $path = $self->publish_file($local_path, catfile($remote_path, $file),
                                $metadata, $timestamp)
  }
  else {
    my $local_md5 = $self->_get_md5($local_path);
    my $obj;
    if ($self->irods->is_object($remote_path)) {
      $self->info("Remote path '$remote_path' is an existing object");
      $obj = $self->_publish_file_overwrite($local_path, $local_md5,
                                            $remote_path, $timestamp);
    }
    else {
      $self->info("Remote path '$remote_path' is a new object");
      $obj = $self->_publish_file_create($local_path, $local_md5,
                                         $remote_path, $timestamp);
    }

    my $num_meta_errors = $self->_supersede_multivalue($obj, $metadata);
    if ($num_meta_errors > 0) {
       $self->logcroak("Failed to update metadata on '$remote_path': ",
                       "$num_meta_errors errors encountered ",
                       '(see log for details)');
     }

    $path = $obj->str;
  }

  return $path;
}

=head2 publish_directory

  Arg [1]    : Path to local directory, Str.
  Arg [2]    : Path to destination in iRODS, Str.
  Arg [3]    : Custom metadata AVUs to add, ArrayRef[HashRef].
  Arg [4]    : Timestamp to use in metadata, DateTime. Optional, defaults
               to current time.

  Example    : my $path = $pub->publish_directory('./local/dir',
                                                  '/zone/path',
                                                  [{attribute => 'x',
                                                    value     => 'y'}])
  Description: Publish a local directory to iRODS, create and/or supersede
               metadata (both default and custom) and update permissions,
               returning the absolute path of the published collection.

               The local directory will be inserted into the destination
               collection as a new sub-collection. No checks are made on the
               files with in the new collection.
  Returntype : Str

=cut

sub publish_directory {
  my ($self, $local_path, $remote_path, $metadata, $timestamp) = @_;

  $self->_check_path_args($local_path, $remote_path);
  -d $local_path or
    $self->logconfess("The local_path argument '$local_path' ",
                      'was not a directory');

  if (defined $metadata and ref $metadata ne 'ARRAY') {
    $self->logconfess('The metadata argument must be an ArrayRef');
  }
  if (not defined $timestamp) {
    $timestamp = DateTime->now;
  }

  $remote_path = $self->_ensure_collection_exists($remote_path);
  my $coll_path = $self->irods->put_collection($local_path, $remote_path);
  my $coll = WTSI::NPG::iRODS::Collection->new($self->irods, $coll_path);

  my @meta = $self->make_creation_metadata($self->affiliation_uri,
                                           $timestamp,
                                           $self->accountee_uri);
  if (defined $metadata) {
    push @meta, @{$metadata};
  }

  my $num_meta_errors = $self->_supersede_multivalue($coll, \@meta);
  if ($num_meta_errors > 0) {
    $self->logcroak("Failed to update metadata on '$remote_path': ",
                    "$num_meta_errors errors encountered ",
                    '(see log for details)');
  }

  return $coll->str;
}

sub _check_path_args {
  my ($self, $local_path, $remote_path) = @_;

  defined $local_path or
    $self->logconfess('A defined local_path argument is required');
  defined $remote_path or
    $self->logconfess('A defined remote_path argument is required');

  $local_path eq q[] and
    $self->logconfess('A non-empty local_path argument is required');
  $remote_path eq q[] and
    $self->logconfess('A non-empty remote_path argument is required');

  $remote_path =~ m{^/}msx or
    $self->logconfess("The remote_path argument '$remote_path' ",
                      'was not absolute');

  return;
}

sub _ensure_collection_exists {
  my ($self, $remote_path) = @_;

  my $collection;
  if ($self->irods->is_object($remote_path)) {
    $self->logconfess("The remote_path argument '$remote_path' ",
                      'was a data object');
  }
  elsif ($self->irods->is_collection($remote_path)) {
    $self->debug("Remote path '$remote_path' is a collection");
    $collection = $remote_path;
  }
  else {
    $collection = $self->irods->add_collection($remote_path);
  }

  return $collection;
}

sub _publish_file_create {
  my ($self, $local_path, $local_md5, $remote_path, $timestamp) = @_;

  $self->debug("Remote path '$remote_path' does not exist");
  my ($loc_vol, $dir, $file)      = splitpath($local_path);
  my ($rem_vol, $coll, $obj_name) = splitpath($remote_path);

  if ($file ne $obj_name) {
    $self->info("Renaming '$file' to '$obj_name' on publication");
  }

  $self->_ensure_collection_exists($coll);
  $self->info("Publishing new object '$remote_path'");

  $self->irods->add_object($local_path, $remote_path,
                           $WTSI::NPG::iRODS::SKIP_CHECKSUM);

  my $obj = WTSI::NPG::iRODS::DataObject->new($self->irods, $remote_path);
  my $num_meta_errors = 0;

  # Calculate checksum post-upload to ensure that iRODS reports errors
  my $remote_md5 = $obj->calculate_checksum;
  my @meta = $self->make_creation_metadata($self->affiliation_uri,
                                           $timestamp,
                                           $self->accountee_uri);
  push @meta, $self->make_md5_metadata($remote_md5);
  push @meta, $self->make_type_metadata($remote_path);

  foreach my $avu (@meta) {
    try {
      $obj->supersede_avus($avu->{attribute}, $avu->{value}, $avu->{units});
    } catch {
      $num_meta_errors++;
      $self->error('Failed to supersede with AVU ', pp($avu), ': ', $_);
    };
  }

  if ($local_md5 eq $remote_md5) {
    $self->info("After publication of '$local_path' ",
                "MD5: '$local_md5' to '$remote_path' ",
                "MD5: '$remote_md5': checksums match");
  }
  else {
    # Maybe tag with metadata to identify a failure?
    $self->logcroak("After publication of '$local_path' ",
                    "MD5: '$local_md5' to '$remote_path' ",
                    "MD5: '$remote_md5': checksum mismatch");
  }

  if ($num_meta_errors > 0) {
    $self->logcroak("Failed to update metadata on '$remote_path': ",
                    "$num_meta_errors errors encountered ",
                    '(see log for details)');
  }

  return $obj;
}

sub _publish_file_overwrite {
  my ($self, $local_path, $local_md5, $remote_path, $timestamp) = @_;

  $self->info("Remote path '$remote_path' is a data object");
  my $obj = WTSI::NPG::iRODS::DataObject->new($self->irods, $remote_path);
  my $num_meta_errors = 0;

  # Assume that the existing checksum is present and correct
  my $pre_remote_md5 = $obj->checksum;
  if ($local_md5 eq $pre_remote_md5) {
    $self->info("Skipping publication of '$local_path' to '$remote_path': ",
                "(checksum unchanged): local MD5 is '$local_md5', ",
                "remote is MD5: '$pre_remote_md5'");
  }
  else {
    $self->info("Re-publishing '$local_path' to '$remote_path' ",
                "(checksum changed): local MD5 is '$local_md5', ",
                "remote is MD5: '$pre_remote_md5'");
    $self->irods->replace_object($local_path, $obj->str,
                                 $WTSI::NPG::iRODS::SKIP_CHECKSUM);

    # Calculate checksum post-upload to ensure that iRODS reports errors
    my $post_remote_md5 = $obj->calculate_checksum;
    my @meta = $self->make_modification_metadata($timestamp);
    push @meta, $self->make_md5_metadata($post_remote_md5);
    push @meta, $self->make_type_metadata($remote_path);

    foreach my $avu (@meta) {
      try {
        $obj->supersede_avus($avu->{attribute}, $avu->{value},
                             $avu->{units});
      } catch {
        $num_meta_errors++;
        $self->error(q[Failed to supersede on '], $obj->str, q[' with AVU ],
                     pp($avu), q[: ], $_);
      };
    }

    if ($local_md5 eq $post_remote_md5) {
      $self->info("Re-published '$local_path' to '$remote_path': ",
                  "(checksums match): local MD5 was '$local_md5', ",
                  "remote was MD5: '$pre_remote_md5', ",
                  "remote now MD5: '$post_remote_md5'");
    }
    elsif ($pre_remote_md5 eq $post_remote_md5) {
      # Maybe tag with metadata to identify a failure?
      $self->logcroak("Failed to re-publish '$local_path' to '$remote_path': ",
                      "(checksum unchanged): local MD5 was '$local_md5', ",
                      "remote was MD5: '$pre_remote_md5', ",
                      "remote now MD5: '$post_remote_md5'");
    }
    else {
      # Maybe tag with metadata to identify a failure?
      $self->logcroak("Failed to re-publish '$local_path' to '$remote_path': ",
                      "(checksum mismatch): local MD5 was '$local_md5', ",
                      "remote was MD5: '$pre_remote_md5', ",
                      "remote now MD5: '$post_remote_md5'");
    }
  }

  if ($num_meta_errors > 0) {
    $self->logcroak("Failed to update metadata on '$remote_path': ",
                    "$num_meta_errors errors encountered ",
                    '(see log for details)');
  }

  return $obj;
}

sub _supersede_multivalue {
  my ($self, $item, $metadata) = @_;

  $self->debug(q[Setting metadata on '], $item->str, q[': ], pp($metadata));

  my $num_meta_errors = 0;
  foreach my $avu (@{$metadata}) {
    try {
      $item->supersede_multivalue_avus($avu->{attribute}, [$avu->{value}],
                                       $avu->{units});
    } catch {
      $num_meta_errors++;
      $self->error(q[Failed to supersede on '], $item->str, q[' with AVU ],
                   pp($avu), q[: ], $_);
    };
  }

  return $num_meta_errors;
}

sub _get_md5 {
  my ($self, $path) = @_;

  defined $path or $self->logconfess('A defined path argument is required');
  -e $path or $self->logconfess("The path '$path' does not exist");

  my ($suffix) = $path =~ m{[.]([^.]+)$}msx;
  my $cache_file = "$path.md5";
  my $md5 = q[];

  if (-e $cache_file and $self->_md5_cache_file_stale($path, $cache_file)) {
    $self->warn("Deleting stale MD5 cache file '$cache_file' for '$path'");
    unlink $cache_file or $self->warn("Failed to unlink '$cache_file'");
  }

  if (-e $cache_file) {
    $md5 = $self->_read_md5_cache_file($cache_file);
  }

  if (not $md5) {
    if ($suffix and any { $suffix eq $_ } @{$self->require_checksum_cache}) {
      $self->logconfess("Missing a populated MD5 cache file '$cache_file'",
                        "for '$path'");
    }
    else {
      $md5 = $self->irods->md5sum($path);

      if (-s $path > $self->checksum_cache_threshold) {
        $self->_make_md5_cache_file($cache_file, $md5);
      }
    }
  }

  return $md5;
}

sub _md5_cache_file_stale {
  my ($self, $path, $cache_file) = @_;

  my $path_stat  = stat $path;
  my $cache_stat = stat $cache_file;

  # Pipeline processes may write the data file and its checksum cache
  # in parallel, leading to mthe possibility that the checksum file
  # handle may be closed before the data file handle. i.e. the data
  # file may be newer than its checksum cache. The test for stale
  # cache files uses a delta to accommodate this; if the data file is
  # newer by more than delta seconds, the cache is considered stale.

  return (($path_stat->mtime - $cache_stat->mtime)
          > $self->checksum_cache_time_delta) ? 1 : 0;
}

sub _read_md5_cache_file {
  my ($self, $cache_file) = @_;

  my $md5 = q[];

  my $in;
  open $in, '<', $cache_file or
    $self->logcarp("Failed to open '$cache_file' for reading: $ERRNO");
  $md5 = <$in>;
  close $in or
    $self->logcarp("Failed to close '$cache_file' cleanly: $ERRNO");

  if ($md5) {
    chomp $md5;

    my $len = length $md5;
    if ($len != 32) {
      $self->error("Malformed ($len character) MD5 checksum ",
                   "'$md5' read from '$cache_file'");
    }
  }
  else {
    $self->logcarp("Malformed (empty) MD5 checksum read from '$cache_file'");
  }

  return $md5;
}

sub _make_md5_cache_file {
  my ($self, $cache_file, $md5) = @_;

  $self->warn("Adding missing MD5 cache file '$cache_file'");

  my $out;
  open $out, '>', $cache_file or
    $self->logcroak("Failed to open '$cache_file' for writing: $ERRNO");
  print $out "$md5\n" or
    $self->logcroak("Failed to write MD5 to '$cache_file'");
  close $out or
    $self->logcarp("Failed to close '$cache_file' cleanly");

  return $cache_file;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::Publisher

=head1 DESCRIPTION

General purpose file/metadata publisher for iRODS. Objects of this
class provide the capability to:

 - Put new files into iRODS

 - Update (overwrite) files already in iRODS

 - Compare local (file system) checksums to remote (iRODS) checksums
   before an upload to determine whether work needs to be done.

 - Compare local (file system) checksums to remote (iRODS) checksums
   after an upload to determine that data were transferred successfully.

 - Cache local (file system) checksums for large files.

 - Add basic metadata to all uploaded files:

   - Creation timestamp

   - Update timestamp

   - File type

   - Entity performing the upload

   See WTSI::NPG::HTS::Annotator.

 - Add custom metadata supplied by the caller.


=head1 AUTHOR

Keith James <kdj@sanger.ac.uk>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2015, 2016 Genome Research Limited. All Rights Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut
