=head1 LICENSE

Copyright [2009-2014] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package EnsEMBL::Web::SpeciesDefs;

#use strict;
use warnings;

use previous qw(retrieve);

sub _get_WUBLAST_source_file { shift->_get_NCBIBLAST_source_file(@_) }

sub _get_NCBIBLAST_source_file {
  my ($self, $species, $source_type) = @_;

  my $assembly = $self->get_config($species, 'ASSEMBLY_NAME');

  (my $type = lc $source_type) =~ s/_/\./;

  my $unit = $self->GENOMIC_UNIT;
  my $path = ($self->EBI_BLAST_DB_PREFIX || "ensemblgenomes") . "/$unit";
  
  my $dataset = $self->get_config($species, 'SPECIES_DATASET');

  if ($species ne $dataset) { # add collection
    $path .= '/' . lc($dataset) . '_collection';
  }

  $path .= '/' . lc $species; # add species folder

  return sprintf '%s/%s.%s.%s', $path, $species, $assembly, $type unless $type =~ /latestgp/;

  $type =~ s/latestgp(.*)/dna$1\.toplevel/;
  $type =~ s/.masked/_rm/;
  $type =~ s/.soft/_sm/;

  return sprintf '%s/%s.%s.%s', $path, $species, $assembly, $type;
}

## EG ENSEMBL-2967 - abbreviate long species names
sub abbreviated_species_label {
  my ($self, $species, $threshold) = @_;
  $threshold ||= 15;

  my $label = $self->species_label($species, 'no_formatting');

  if (length $label > $threshold) {
    my @words = split /\s/, $label;
    if (@words == 2) {
      $label = substr($words[0], 0, 1) . '. ' . $words[1];
    } elsif (@words > 2) {
      $label = join '. ', substr(shift @words, 0, 1), substr(shift @words, 0, 1), join(' ', @words);
    }
  }

  return $label;
}
##

#------------------------------------------------------------------------------
# MULTI SPECIES
#------------------------------------------------------------------------------

sub _parse {
  ### Does the actual parsing of .ini files
  ### (1) Open up the DEFAULTS.ini file(s)
  ### Foreach species open up all {species}.ini file(s)
  ###  merge in content of defaults
  ###  load data from db.packed file
  ###  make other manipulations as required
  ### Repeat for MULTI.ini
  ### Returns: boolean

  my $self = shift; 
  $CONF->{'_storage'} = {};

  $self->_info_log('Parser', 'Starting to parse tree');

  my $tree          = {};
  my $db_tree       = {};
  my $config_packer = EnsEMBL::Web::ConfigPacker->new($tree, $db_tree);
  
  $self->_info_line('Parser', 'Child objects attached');

  # Parse the web tree to create the static content site map
  $tree->{'STATIC_INFO'}  = $self->_load_in_webtree;
  $self->_info_line('Filesystem', 'Trawled web tree');
  
  $self->_info_log('Parser', 'Parsing ini files and munging dbs');
  
  # Grab default settings first and store in defaults
  my $defaults = $self->_read_in_ini_file('DEFAULTS', {});
  $self->_info_line('Parsing', 'DEFAULTS ini file');

 
  # Loop for each species exported from SiteDefs
  # grab the contents of the ini file AND
  # IF  the DB packed files exist expand them
  # o/w attach the species databases
  # load the data and store the packed files
  foreach my $species (@$SiteDefs::PRODUCTION_NAMES, 'MULTI') {
    $config_packer->species($species);
    
    $self->process_ini_files($species, $config_packer, $defaults);
    $self->_merge_db_tree($tree, $db_tree, $species);
  }

  $self->_info_log('Parser', 'Post processing ini files');
 
  # Prepare to process strain information
  my $species_to_strains = {};
  my $species_to_assembly = {};
 
  # Loop over each tree and make further manipulations
  foreach my $species (@$SiteDefs::PRODUCTION_NAMES, 'MULTI') {
    $config_packer->species($species);
    $config_packer->munge('config_tree');
    $self->_info_line('munging', "$species config");

    ## Need to gather strain info for all species
    my $strain_group = $config_packer->tree->{'STRAIN_GROUP'};
    my $strain_name = $config_packer->tree->{'SPECIES_STRAIN'};
    my $species_key = $config_packer->tree->{'SPECIES_URL'}; ## Key on actual URL, not production name
    if ($strain_group && $strain_name !~ /reference/) {
      if ($species_to_strains->{$strain_group}) {
        push @{$species_to_strains->{$strain_group}}, $species_key;
      }
      else {
        $species_to_strains->{$strain_group} = [$species_key];
      }
    }

  } 

 ## Compile strain info into a single structure
  while (my($k, $v) = each (%$species_to_strains)) {
    $tree->{$k}{'ALL_STRAINS'} = $v;
  } 

# use Data::Dumper; 
# $Data::Dumper::Maxdepth = 2;
# $Data::Dumper::Sortkeys = 1;
# warn ">>> ORIGINAL KEYS: ".Dumper($tree);

  ## Final munging
  my $datasets = [];

## EG - loop through ALL keys; we can't use @$SiteDefs::PRODUCTION_NAMES as per Ensembl 
##      because that list doesn't include genomes in the collection dbs         
  foreach my $key (sort keys %$tree) {
    next unless (defined $tree->{$key}{'SPECIES_URL'}); # skip if not a species key
    my $prodname = $key;

    my $url = $tree->{$prodname}{'SPECIES_URL'};

    ## Add in aliases to production names
    $aliases->{$prodname} = $url;

    ## Rename the tree keys for easy data access via URLs
    ## (and backwards compatibility!)
    $tree->{$url} = $tree->{$prodname};
    push @$datasets, $url;
    delete $tree->{$prodname} if $prodname ne $url;
  }

  # For EG we need to merge collection info into the species hash
  foreach my $prodname (@$SiteDefs::PRODUCTION_NAMES) {
    next unless $tree->{$prodname};
    my @db_species = @{$tree->{$prodname}->{DB_SPECIES}};
    my $species_lookup = { map {$_ => 1} @db_species };
    foreach my $sp (@db_species) {
      $self->_merge_species_tree( $tree->{$sp}, $tree->{$prodname}, $species_lookup);
    } 
  }
##
  
  ## Assign an image to this species
  foreach my $key (sort keys %$tree) {
    next unless (defined $tree->{$key}{'SPECIES_URL'}); # skip if not a species key
    ## Check for a) genome-specific image, b) species-specific image
    my $no_image  = 1;
    ## Need to use full path, as image files are usually in another plugin
    my $image_dir = sprintf '%s/eg-web-%s/htdocs/i/species', $SiteDefs::ENSEMBL_SERVERROOT, $SiteDefs::DIVISION;
    my $image_path = sprintf '%s/%s.png', $image_dir, $key;
    ## In theory this could be a trinomial, but we use whatever is set in species.species_name
    my $binomial = $tree->{$key}{SPECIES_BINOMIAL};
    if ($bionomial) {
      $bionomial =~ s/ /_/g;
    }
    else {
      ## Make a guess based on URL. Note that some fungi have weird URLs bc 
      ## their taxonomy is uncertain, so this regex doesn't try to include them
      ## (none of them have images in any case)
      $key =~ /^([A-Za-z]+_[a-z]+)/;
      $binomial = $1;
    }
    my $species_path = $binomial ? sprintf '%s/%s.png', $image_dir, $binomial : '';
    if (-e $image_path) {
      $tree->{$key}{'SPECIES_IMAGE'} = $key;
      $no_image = 0;
    }
    elsif ($species_path && -e $species_path) {
      $tree->{$key}{'SPECIES_IMAGE'} = $binomial;
      $no_image = 0;
    }
    else {
      $tree->{$key}{'SPECIES_IMAGE'} = 'default';
      $no_image = 0;
    }
  }

  $tree->{'MULTI'}{'ENSEMBL_DATASETS'} = $datasets;
  #warn ">>> NEW KEYS: ".Dumper($tree);

  ## Parse species directories for static content
  $tree->{'SPECIES_INFO'} = $self->_load_in_species_pages;
  $CONF->{'_storage'} = $tree; # Store the tree
  $self->_info_line('Filesystem', 'Trawled species static content');

}

our %cow_from_defaults = ( # copy-on-write from defautls for these sections.
                          'ENSEMBL_SPECIES_SITE'  => 1,
                          'SPECIES_DISPLAY_NAME'  => 1 );

$cow_from_defaults{'ENSEMBL_EXTERNAL_URLS'} = 1 if $SiteDefs::ENSEMBL_SITETYPE =~ /bacteria/i;

sub _merge_db_tree {
  my ($self, $tree, $db_tree, $key) = @_;
  return unless defined $db_tree;
  Hash::Merge::set_behavior('RIGHT_PRECEDENT');
  my $t = merge($tree->{$key}, $db_tree->{$key});
  foreach my $k ( %cow_from_defaults ) {
      $t->{$k} = $tree->{$key}->{$k} if defined $tree->{$key}->{$k};
  }

  $tree->{$key} = $t;
}

## EG to overwrite behaviour on ensembl-webcode in which the sections in default ones are deep-copied into species defs regardless
## whether there is update in the species ini file.
## For EG, we want only copy-on-write. The sections specified in default will only be deep-copied into species defs when there is
## update for the same section in the species ini file. Otherwise, use hashref to point to the one in default.
## This is based on Ensembl implementation at https://github.com/Ensembl/ensembl-webcode/blob/release/87/modules/EnsEMBL/Web/SpeciesDefs.pm#L469-L531
sub _read_in_ini_file {
  my ($self, $filename, $defaults) = @_;
  my $inifile = undef;
  my $tree    = {};

  foreach my $confdir (@SiteDefs::ENSEMBL_CONF_DIRS) {
    if (-e "$confdir/ini-files/$filename.ini") {
      if (-r "$confdir/ini-files/$filename.ini") {
        $inifile = "$confdir/ini-files/$filename.ini";
      } else {
        warn "$confdir/ini-files/$filename.ini is not readable\n" ;
        next;
      }

      open FH, $inifile or die "Problem with $inifile: $!";
      
      my $current_section = undef;
      my $defaults_used   = 0;
      my $line_number     = 0;

      while (<FH>) {


        # parse any inline perl <% perl code %>
        s/<%(.+?(?=%>))%>/eval($1)/ge;

        s/\s+[;].*$//; # These two lines remove any comment strings
        s/^[#;].*$//;  # from the ini file - basically ; or #..
        
        if (/^\[\s*(\w+)\s*\]/) { # New section - i.e. [ ... ]
          $current_section = $1;

          if ( defined $defaults->{$current_section} && exists $cow_from_defaults{$current_section} ) {
            $tree->{$current_section} = $defaults->{$current_section};
            $defaults_used = 1;  
          }
          else {
            $tree->{$current_section} ||= {}; # create new element if required
            $defaults_used = 0;  
            if (defined $defaults->{$current_section}) {
              my %hash = %{$defaults->{$current_section}};
              $tree->{$current_section}{$_} = $defaults->{$current_section}{$_} for keys %hash;
            }
          }
        } elsif (/([\w*]\S*)\s*=\s*(.*)/ && defined $current_section) { # Config entry
          my ($key, $value) = ($1, $2); # Add a config entry under the current 'top level'
          $value =~ s/\s*$//;
          
          # [ - ] signifies an array
          if ($value =~ /^\[\s*(.*?)\s*\]$/) {
            my @array = split /\s+/, $1;
            $value = \@array;
          }

          if ( $defaults_used && defined $defaults->{$current_section} ) {
            my %hash = %{$defaults->{$current_section}};
            $tree->{$current_section}{$_} = $defaults->{$current_section}{$_} for keys %hash;             
            $defaults_used = 0;
          } 

          $tree->{$current_section}{$key} = $value;
        } elsif (/([.\w]+)\s*=\s*(.*)/) { # precedes a [ ] section
          print STDERR "\t  [WARN] NO SECTION $filename.ini($line_number) -> $1 = $2;\n";
        }
        
        $line_number++;
      }
      
      close FH;
    }

    # Check for existence of VCF JSON configuration file
    my $json_path = "$confdir/json/${filename}_vcf.json";
    if (-e $json_path) {
      $tree->{'ENSEMBL_VCF_COLLECTIONS'} = {'CONFIG' => $json_path, 'ENABLED' => 1} if $json_path;
    }
  }

  return $inifile ? $tree : undef;
}

## EG MULTI
sub _merge_species_tree {
  my ($self, $a, $b, $species_lookup) = @_;

  foreach my $key (keys %$b) {
## EG - don't bloat the configs with references to all the other speices in this dataset    
      next if $species_lookup->{$key}; 
##
      $a->{$key} = $b->{$key} unless exists $a->{$key};
  }
}
##


## EG always return true so that we never force a config repack
##    this allows us to run util scripts from a different server to where the configs were packed
sub retrieve {
  my $self = shift;
  $self->PREV::retrieve;
  return 1; 
}
##

sub production_name_mapping {
  ### As the name said, the function maps the production name with the species URL,
  ### @param production_name - species production name
  ### Return string = the corresponding species url name, which is the name web uses for URL and other code, or production name as fallback
  my ($self, $production_name) = @_;
  my $mapping_name = '';

  ## EG - in EG we still use production name. Don't need to map them into url name.
  foreach ($self->valid_species) {
    if ($self->get_config($_, 'SPECIES_PRODUCTION_NAME') eq lc($production_name)) {
      $mapping_name = $self->get_config($_, 'SPECIES_URL');
      last;
    }
  }

  ## EG - species may be from another divison or from external site (e.g. Ensembl)
  ## There are instances where species url is returned
  ## When it isn't returned then production name can be used instead
  return $mapping_name || $production_name;
}

1;
