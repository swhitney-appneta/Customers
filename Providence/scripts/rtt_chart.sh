#!/bin/bash
#set -x
#trap read debug

#######################################################################################
# Author: Sean Whitney <sean.whitney@broadcom.com>                                    #
# For use by Providence Health Care Organization                                      #
#######################################################################################
# This script makes a couple of assumptions                                           #
# 1. There is another directory ../sql that contains the API2SQL code and the         #
#    api.sqlt database.                                                               #
# 2. The ../sql/api.sqlt database has been initialized using ./build_apm_db.sh -i     #
# 3. This copy of the api.sqlt database is dedicated to this script and isn't         #
#    supporting any other sqlite database write operations.  Please contact the       #
#    author if this is requirement changes.                                           #
#                                                                                     #
# Generally this script should be run out of cron or another scheduling tool, the     #
# -d option is expected to be run manually only                                       #
#######################################################################################

SL="$(which sqlite3) -batch -init /dev/null "
LOCAL_DB="../sql/api.sqlt"
# By default the database will contain 8 days of data, but only reporting on the
# last week (based on the top of the last hour).  If there is a need to store less
# data then change the variable OLDDATE (currently 60sec*60min*24hours*8days)
# Tried larger values, it made operations slower without any additional value.
OLDDATE=691200

# By default the results will be based on a average of 1 weeks worth of data
PERIOD=604800

#######################################################################################
# Functions                                                                           #
#######################################################################################
debug() {
	test "$V" == "true" && echo "$1"
}

update_db() {
	TABLE="${1}"
	if [[ ! ${#TABLE} -gt 1 ]]; then
		TABLE="appliance"
	fi
	# all build_db* scripts expect to be run in the local directory, so...
	cd ../sql >/dev/null || exit
	./build_apm_db.sh -o "$TABLE"
	cd - >/dev/null || exit
}

delete_views() {
	SQL="PRAGMA journal_mode=WAL;
         DROP VIEW IF EXISTS appliance_ip_not_n10_view;
         DROP VIEW IF EXISTS rtt_target_id_view;
         DROP VIEW IF EXISTS rtt_path_id_view;
         DROP VIEW IF EXISTS rtt_weekly_avg_view;
         DROP VIEW IF EXISTS rtt_results_view;
         DROP VIEW IF EXISTS rtt_raw_results_view;
         DROP VIEW IF EXISTS rtt_table_view;
         VACUUM"
	$SL "$LOCAL_DB" "$SQL"
	exit 0
}

info() {
	BN=$(which basename)
	FN=$("$BN" "$0")

	# -v is used for debugging and not included in the info page.
	echo
	echo "$FN creates several views and uses them to create a view with rtt times between"
	echo "selected monitoring points. This script can take a long time to run, but should"
	echo "complete within a few hours."
	echo "Usage: $FN [-dh]"
	echo "  -d  deletes existing views created by this script and exits.  The script will"
	echo "      automatically recreate these views the next time it runs "
	echo "  -h  shows help, this screen"
	echo
	exit 1
}

#######################################################################################
# Main                                                                                #
#######################################################################################

opt=":dhv"

while getopts "$opt" arg; do
	case "$arg" in
	d) delete_views ;; # This can be used to recreate view if needed
	h) info ;;
	v) V="true" ;;
	?)
		echo "Invalid option: -${OPTARG}"
		echo
		info
		;;
	esac
done
# Update database appliance paths
update_db appliance,path

# Delete any data from pathdata_data over 8 days old
# then shrink the database
SQL="DELETE FROM pathdata_data
     WHERE START < (STRFTIME('%s','now')-"$OLDDATE")*1000"

debug "$SQL"

$SL "$LOCAL_DB" "$SQL"

#######################################################################################
# Create main views                                                                   #
#######################################################################################

# Parse out network interface prior to running, create view if not exists
SQL="CREATE VIEW IF NOT EXISTS appliance_ip_not_n10_view AS
       SELECT a.id AS fid, a.name,
       SUBSTR(l.localNetworkInterfaces,INSTR(l.localNetworkInterfaces,' - ')+3,
          INSTR(l.localNetworkInterfaces,'/')-INSTR(l.localNetworkInterfaces,' - ')-3) AS ip,
       SUBSTR(l.localNetworkInterfaces,INSTR(l.localNetworkInterfaces,'/')+1) AS mask, 
       SUBSTR(l.localNetworkInterfaces,0,INSTR(l.localNetworkInterfaces,' - ')) AS interface
       FROM appliance_lninterface l 
       JOIN appliance a ON a.id=l.fid 
       WHERE a.os NOT IN ('Windows','macOS')"
$SL "$LOCAL_DB" "$SQL"

# Define column ids
SQL="CREATE VIEW IF NOT EXISTS rtt_target_id_view AS
       SELECT DISTINCT * FROM appliance 
         WHERE 
           (os IN ('c50 Container', 'r90 rackAppliance') 
            OR name LIKE '%Equinix' 
            OR name IN ('AKPRBDCNT-MDF01-AN01--AlaskaDC','TXTXRDCNT-MDF01-AN01--TexasDC'))
         AND name NOT LIKE '%private_hub%'"
$SL "$LOCAL_DB" "$SQL"

# Define row ids
SQL="CREATE VIEW IF NOT EXISTS rtt_path_id_view AS
       SELECT p.* FROM path p
           JOIN appliance_ip_not_n10_view i ON i.ip=p.target 
           JOIN rtt_target_id_view l ON l.id=i.fid 
           JOIN appliance a ON  a.name=p.sourceAppliance 
           WHERE a.os in ('c50 Container','r90 rackAppliance','m70 microAppliance') 
             AND p.applianceInterface LIKE 'eth0%'
       UNION
       SELECT p.* FROM path p 
           JOIN rtt_target_id_view l ON l.name=p.sourceAppliance
           JOIN appliance_ip_not_n10_view i ON i.ip=p.target
           JOIN appliance a on a.id=i.fid
           WHERE a.os in ('c50 Container','r90 rackAppliance','m70 microAppliance') 
              AND p.applianceInterface like 'eth0%'"
$SL "$LOCAL_DB" "$SQL"

# This isn't really needed but doesn't take and resources to create.  PowerBI
# importing might be easier with this view
# Create rtt_weekly_avg_view if not created
SQL="CREATE VIEW IF NOT EXISTS rtt_weekly_avg_view AS
       SELECT pathId, round(avg(value),1) AS rtt_avg
       FROM pathdata_data 
       WHERE type='rtt' 
       AND period IS NULL
       AND start BETWEEN 
         ((STRFTIME('%s','now')/3600)*3600-"$PERIOD")*1000 AND 
         (STRFTIME('%s','now')/3600)*3600*1000 
       GROUP BY pathId"
$SL "$LOCAL_DB" "$SQL"

# Create the raw results view
SQL="CREATE VIEW IF NOT EXISTS rtt_results_view AS
       SELECT pathId, value AS rtt 
       FROM pathdata_data 
       WHERE type='rtt' 
       AND period IS NULL
       AND start BETWEEN ((STRFTIME('%s','now')/3600)*3600-"$PERIOD")*1000 
       AND (STRFTIME('%s','now')/3600)*3600*1000"
$SL "$LOCAL_DB" "$SQL"

# Create the raw results table to support the pivot table creation
SQL="CREATE VIEW IF NOT EXISTS rtt_raw_results_view AS
       SELECT p.description, p.sourceAppliance, t.name AS targetAppliance, r.rtt 
       FROM rtt_path_id_view p 
       JOIN rtt_results_view r ON r.pathId=p.id 
       JOIN appliance_ip_not_n10_view i ON i.ip=p.target 
       JOIN rtt_target_id_view t on t.id=i.fid"
$SL "$LOCAL_DB" "$SQL"

# This view creates the final rtt_table
SQL="CREATE VIEW IF NOT EXISTS rtt_table_view AS
       SELECT sourceAppliance, 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-east-private'
            THEN rtt END),1) AS 'az-us-east-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-northcentral-private'
            THEN rtt END),1) AS 'az-us-northcentral-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-southcentral-private'
            THEN rtt END),1) AS 'az-us-southcentral-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-west-private' 
            THEN rtt END),1) AS 'az-us-west-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-west2-private' 
            THEN rtt END),1) AS 'az-us-west2-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-west3-private' 
            THEN rtt END),1) AS 'az-us-west3-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-westcentral-private' 
            THEN rtt END),1) AS 'az-us-westcentral-private', 
        ROUND(AVG(CASE WHEN targetAppliance='AKPRBDCNT-MDF01-AN01--AlaskaDC'
            THEN rtt END),1) AS 'AKPRBDCNT-MDF01-AN01--AlaskaDC',
        ROUND(AVG(CASE WHEN targetAppliance='CALAEQX-C030R510-AN01--SoCalEquinix'
            THEN rtt END),1) AS 'CALAEQX-C030R510-AN01--SoCalEquinix',
        ROUND(AVG(CASE WHEN targetAppliance='CASVEQX-2160R106-AN01--SiliconValleyEquinix'
            THEN rtt END),1) AS 'CASVEQX-2160R106-AN01--SiliconValleyEquinix',
        ROUND(AVG(CASE WHEN targetAppliance='NVLVRDCNT-C5241-AN01--VegasDC'
            THEN rtt END),1) AS 'NVLVRDCNT-C5241-AN01--VegasDC',
        ROUND(AVG(CASE WHEN targetAppliance='TXEQUNXNT-00111-AN01--DallasTexasEquinix'
            THEN rtt END),1) AS 'TXEQUNXNT-00111-AN01--DallasTexasEquinix',
        ROUND(AVG(CASE WHEN targetAppliance='TXTXRDCNT-MDF01-AN01--TexasDC'
            THEN rtt END),1) AS 'TXTXRDCNT-MDF01-AN01--TexasDC',
        ROUND(AVG(CASE WHEN targetAppliance='WAQCYDCNT-05B12-AN01-QuincyDC'
            THEN rtt END),1) AS 'WAQCYDCNT-05B12-AN01-QuincyDC',
        ROUND(AVG(CASE WHEN targetAppliance='WASEEQX-00000309-AN01--KentWAEquinix'
            THEN rtt END),1) AS 'WASEEQX-00000309-AN01--KentWAEquinix',
        ROUND(AVG(CASE WHEN targetAppliance='WATKWDCNT-05A06-AN01--TukwilaDC'
            THEN rtt END),1) AS 'WATKWDCNT-05A06-AN01--TukwilaDC'  
       FROM rtt_raw_results_view
       GROUP BY sourceAppliance"

$SL "$LOCAL_DB" "$SQL"

#######################################################################################
# Use the rtt_path_id_view to generate a list of paths ids for processing by          #
# build_apm_paths_data.sh                                                             #
#######################################################################################

SQL="select group_concat(id) from rtt_path_id_view"

PATH_IDS=$($SL "$LOCAL_DB" "$SQL")

cd ../sql >/dev/null || exit
./build_apm_paths_data.sh -p "$PATH_IDS"
cd - >/dev/null || exit

#######################################################################################
# Use the rtt_path_id_view to generate a list of paths ids for processing by          #
# build_apm_paths_data.sh  It could be possible to name these tables with dates and   #
# leave several in place...                                                           #
#######################################################################################

SQL="DROP TABLE IF EXISTS rtt_table;
     CREATE TABLE IF NOT EXISTS rtt_table AS
       SELECT sourceAppliance, 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-east-private'
            THEN rtt END),1) AS 'az-us-east-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-northcentral-private'
            THEN rtt END),1) AS 'az-us-northcentral-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-southcentral-private'
            THEN rtt END),1) AS 'az-us-southcentral-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-west-private' 
            THEN rtt END),1) AS 'az-us-west-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-west2-private' 
            THEN rtt END),1) AS 'az-us-west2-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-west3-private' 
            THEN rtt END),1) AS 'az-us-west3-private', 
        ROUND(AVG(CASE WHEN targetAppliance='az-us-westcentral-private' 
            THEN rtt END),1) AS 'az-us-westcentral-private', 
        ROUND(AVG(CASE WHEN targetAppliance='AKPRBDCNT-MDF01-AN01--AlaskaDC'
            THEN rtt END),1) AS 'AKPRBDCNT-MDF01-AN01--AlaskaDC',
        ROUND(AVG(CASE WHEN targetAppliance='CALAEQX-C030R510-AN01--SoCalEquinix'
            THEN rtt END),1) AS 'CALAEQX-C030R510-AN01--SoCalEquinix',
        ROUND(AVG(CASE WHEN targetAppliance='CASVEQX-2160R106-AN01--SiliconValleyEquinix'
            THEN rtt END),1) AS 'CASVEQX-2160R106-AN01--SiliconValleyEquinix',
        ROUND(AVG(CASE WHEN targetAppliance='NVLVRDCNT-C5241-AN01--VegasDC'
            THEN rtt END),1) AS 'NVLVRDCNT-C5241-AN01--VegasDC',
        ROUND(AVG(CASE WHEN targetAppliance='TXEQUNXNT-00111-AN01--DallasTexasEquinix'
            THEN rtt END),1) AS 'TXEQUNXNT-00111-AN01--DallasTexasEquinix',
        ROUND(AVG(CASE WHEN targetAppliance='TXTXRDCNT-MDF01-AN01--TexasDC'
            THEN rtt END),1) AS 'TXTXRDCNT-MDF01-AN01--TexasDC',
        ROUND(AVG(CASE WHEN targetAppliance='WAQCYDCNT-05B12-AN01-QuincyDC'
            THEN rtt END),1) AS 'WAQCYDCNT-05B12-AN01-QuincyDC',
        ROUND(AVG(CASE WHEN targetAppliance='WASEEQX-00000309-AN01--KentWAEquinix'
            THEN rtt END),1) AS 'WASEEQX-00000309-AN01--KentWAEquinix',
        ROUND(AVG(CASE WHEN targetAppliance='WATKWDCNT-05A06-AN01--TukwilaDC'
            THEN rtt END),1) AS 'WATKWDCNT-05A06-AN01--TukwilaDC'  
       FROM rtt_raw_results_view
       GROUP BY sourceAppliance"

$SL "$LOCAL_DB" "$SQL"

#######################################################################################
# Output the results to a dated file                                                  #
#######################################################################################
#TS=$(date '+%Y%m%d%H')
OUTPUT=rtt_table.csv
test -f "$OUTPUT" && rm "$OUTPUT" || exit

$SL "$LOCAL_DB" <<EOF
.mode csv
.headers on
.output $OUTPUT
select * from rtt_table;
EOF
