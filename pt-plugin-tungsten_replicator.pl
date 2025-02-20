## CONFIGURATION
# trepctl command to run
my $trepctl="/opt/tungsten/installs/cookbook/tungsten/tungsten-replicator/bin/trepctl";

# what tungsten replicator service to check
my $service="bravo";

# what user does tungsten replicator use to perform the writes?
# See Binlog Format for more information
my $tungstenusername = 'tungsten';

# ###############################################################
# The actual get_slave_lag which is invoked by the plugin classes
# ###############################################################
{
package plugin_tungsten_replicator;

use Data::Dumper;
local $Data::Dumper::Indent    = 1;
local $Data::Dumper::Sortkeys  = 1;
local $Data::Dumper::Quotekeys = 0;

use JSON::XS;

sub get_slave_lag {
   my ($self, %args) = @_;
   # oktorun is a reference, also update it using $$oktorun=0;
   my $oktorun=$args{oktorun};
   
   print "PLUGIN get_slave_lag: Using Tungsten Replicator to check replication lag\n";

   my $get_lag = sub {
         my ($cxn) = @_;

         my $hostname = $cxn->{hostname};
         my $lag;
         my $json = `$trepctl -host $hostname -service $service status -json`;

         # if trepctl doesn't return 0, something went wrong and we should abort 
         # the complete process
         my $return = $? >> 8;
         if ( $return != 0 )
         {
            $$oktorun=0;
            die "\nCould not run trepctl successfully for $hostname in order to get replication lag:\n"
               . $json;

         }

         ## In Continuent Tungsten v6, trepctl status was modified to return an array of objects
         ## Thus even if the service is explicitly specified, the json still returns an array of 1 object.
         my $decoded = decode_json $json;
         my $status = pop $decoded;


         if ( $status->{state} ne "ONLINE" ) {
            print "Tungsten Replicator status of host $hostname is " . $status->{state} . ", waiting\n";
            return;
         }

	 # Changed from appliedLatency to relativeLatency
         $lag = sprintf("%.0f", $status->{relativeLatency});

         # we return oktorun and the lag
         return $lag;
   };

   return $get_lag;
}

}
1;
# #############################################################################
# pt_online_schema_change_plugin
# #############################################################################
{
package pt_online_schema_change_plugin;

use Data::Dumper;
local $Data::Dumper::Indent    = 1;
local $Data::Dumper::Sortkeys  = 1;
local $Data::Dumper::Quotekeys = 0;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ($class, %args) = @_;
   my $self = { %args };
   my $dbh = $self->{cxn}->dbh();

   my ($binlog_format) = $dbh->selectrow_array('SELECT @@GLOBAL.binlog_format as binlog_format');

   if ( $binlog_format eq "STATEMENT" ) {
      $self->{custom_triggers} = 0;
   } elsif ( $binlog_format eq "ROW" ) {
      $self->{custom_triggers} = 1;
   } elsif ( $binlog_format eq "MIXED" ) {
      die ("The master it's binlog_format=MIXED," 
               . " pt-online-schema change does not work well with "
               . "Tungsten Replicator and binlog_format=MIXED.\n");
   } else {
      die ("Invalid binlog_format: " . $binlog_format . "\n");
   }

   return bless $self, $class;

}

sub get_slave_lag {
   return plugin_tungsten_replicator::get_slave_lag(@_);
}

sub after_create_triggers {
   my ($self, %args) = @_;

   if ( $self->{custom_triggers} == 1 ) {

      my $dbh = $self->{cxn}->dbh();
      my $schema = $self->{cxn}->{dsn}->{D};
      my $table = $self->{cxn}->{dsn}->{t};

      my $dbhtriggers = $dbh->prepare("SHOW TRIGGERS IN " . $schema . " LIKE '" . $table . "'");
      $dbhtriggers->execute();
      my $trigger;
      while ( $trigger = $dbhtriggers->fetchrow_hashref() ) {

         $dbh->do("DROP TRIGGER " . $schema . "." . $trigger->{trigger})
            or die ("PLUGIN was unable to drop the existing trigger in order to replace it"
                     . " with a tungsten replicator compatible one\n.");

         $dbh->do("CREATE TRIGGER " . $trigger->{trigger} . " " 
                  . $trigger->{timing} . " " . $trigger->{event}
                  . " ON $schema.$table "
                  . " FOR EACH ROW "
                  . " IF if(substring_index(user(),'\@',1) != '$tungstenusername',true, false) THEN "
                  . " " . $trigger->{statement} . "; "
                  . " END IF"
                  )
            or die("PLUGIN could not create tungsten replicator compatible trigger\n");
      }
   }   
}

}
1;

# #############################################################################
# pt_table_checksum_plugin
# #############################################################################
{
package pt_table_checksum_plugin;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ($class, %args) = @_;
   my $self = { %args };
   return bless $self, $class;
}

sub get_slave_lag {
   return plugin_tungsten_replicator::get_slave_lag(@_);
}

}
1;
