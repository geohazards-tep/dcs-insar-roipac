#!/bin/bash


# source the ciop functions (e.g. ciop-log)
source ${ciop_job_include}

# define the exit codes
SUCCESS=0
ERR_INVALIDFORMAT=2
ERR_NOIDENTIFIER=5
ERR_NODEM=7

# add a trap to exit gracefully
function cleanExit ()
{
local retval=$?
local msg=""
case "$retval" in
$SUCCESS) msg="Processing successfully concluded";;
$ERR_INVALIDFORMAT) msg="Invalid format must be roi_pac or gamma";;
$ERR_NOIDENTIFIER) msg="Could not retrieve the dataset identifier";;
$ERR_NODEM) msg="DEM not generated";;
*) msg="Unknown error";;
esac
[ "$retval" != "0" ] && ciop-log "ERROR" "Error $retval - $msg, processing aborted" || ciop-log "INFO" "$msg"
exit $retval
}
trap cleanExit EXIT

# for all input ASAR products, retrieve the auxiliary products
# ASA_CON_AX
# ASA_INS_AX
# ASA_XCA_AX
# ASA_XCH_AX

# and orbit data
# DOR_VOR_AX

function getAUXref() {
  local rdf=$1
  local ods=$2
 
  startdate="`ciop-casmeta -f "ical:dtstart" $rdf | tr -d "Z"`"
  stopdate="`ciop-casmeta -f "ical:dtend" $rdf | tr -d "Z"`"
 
	opensearch-client -f Rdf \
		-p time:start=$startdate \
		-p time:end=$stopdate \
		$ods
}

while read input
do
	ciop-log "INFO" "dealing with $input"
	
	
	
	# pass the SAR reference to the next job
	echo "sar=$input" | ciop-publish -s
done