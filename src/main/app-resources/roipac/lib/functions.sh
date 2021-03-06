
# define the exit codes
SUCCESS=0
ERR_AUX=4
ERR_VOR=6
ERR_INVALIDFORMAT=2
ERR_NOIDENTIFIER=5
ERR_NODEM=7
ERR_PROCESS2PASS=10
ERR_SAR_DATE=15
ERR_SAR_IDENTIFIER=20
ERR_SAR_ENCLOSURE=25
ERR_SAR=30
ERR_MAKE_RAW=35

# add a trap to exit gracefully
function cleanExit ()
{
    local retval=$?
    local msg=""
    case "${retval}" in
        ${SUCCESS}) msg="Processing successfully concluded";;
        ${ERR_AUX}) msg="Failed to retrieve auxiliary products";;
        ${ERR_VOR}) msg="Failed to retrieve orbital data";;
        ${ERR_INVALIDFORMAT}) msg="Invalid format must be roi_pac or gamma";;
        ${ERR_NOIDENTIFIER}) msg="Could not retrieve the dataset identifier";;
        ${ERR_NODEM}) msg="DEM not generated";;
        ${ERR_SAR_DATE}) msg="Could not get SAR date";;
        ${ERR_SAR_IDENTIFIER}) msg="Could not get SAR identifier";;
        ${ERR_SAR_ENCLOSURE}) msg="Could not get SAR enclosure";;
        ${ERR_SAR}) msg="Could not retrieve SAR product";;
	${ERR_MAKE_RAW}) msg="Failed to convert SAR to ROI_PAC format (make_raw)";;
        ${ERR_PROCESS2PASS}) msg="ROI_PAC failed to process pair";;
        *) msg="Unknown error";;
    esac

    [ "${retval}" != "0" ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"
    exit ${retval}
}

trap cleanExit EXIT

function set_env() {

  # create a shorter TMPDIR name for some ROI_PAC scripts/binaires
  UUIDTMP="/tmp/$( uuidgen )"

  mkdir ${UUIDTMP}
  export TMPDIR=${UUIDTMP}

  ciop-log "INFO" "working in tmp dir [${TMPDIR}]"

  # prepare ROI_PAC environment variables
  export INT_BIN=/usr/bin/
  export INT_SCR=/usr/share/roi_pac
  export PATH=${INT_BIN}:${INT_SCR}:${PATH}

  mkdir -p ${TMPDIR}/aux
  mkdir -p ${TMPDIR}/vor
  mkdir -p ${TMPDIR}/workdir/dem

  export SAR_ENV_ORB=${TMPDIR}/aux
  export VOR_DIR=${TMPDIR}/vor
  export INS_DIR=${SAR_ENV_ORB}

  # the path to the ROI_PAC proc file
  export roipac_proc=$TMPDIR/workdir/roi_pac.proc

}

function get_aux() {

  # retrieve the aux files

  for input in $( cat ${TMPDIR}/input | grep 'aux=' )
  do
    ciop-log "INFO" "retrieving aux file ${input#aux=}"

    ref=$( echo ${input#aux=} )
    enclosure="$( opensearch-client ${ref} enclosure )"
    [ -z "${enclosure}" ] && return ${ERR_AUX}

    ciop-copy -O ${TMPDIR}/aux ${enclosure} 
    [ $? -ne 0 ] && return ${ERR_AUX}

  done

}

function get_orbit() {

  # retrieve the orbit data 
  for input in $( cat ${TMPDIR}/input | grep 'vor=' )
  do
    ciop-log "INFO" "retrieving orbit file ${input#vor=}"

    ref=$( echo ${input#vor=} )
    enclosure="$( opensearch-client ${ref} enclosure )"
    [ -z "${enclosure}" ] && return ${ERR_VOR}

    ciop-copy -O ${TMPDIR}/vor ${enclosure} 
    [ $? -ne 0 ] && return ${ERR_VOR}

  done

}

function get_dem() {

  # retrieve the DEM
  demRes="$( cat ${TMPDIR}/input | grep 'node_dem')"
  wps_result="$( ciop-browseresults -R ${demRes} | tr -d '\r')" #just a parser of result.xml and metalink
  ciop-log "DEBUG" "dem wps results is ${wps_result}"

  # extract the result URL
  curl -L -o ${TMPDIR}/workdir/dem/dem.tgz "${wps_result}" 2> /dev/null
  [ ! -e ${TMPDIR}/workdir/dem/dem.tgz ] && return ${ERR_NODEM}

  tar xzf ${TMPDIR}/workdir/dem/dem.tgz -C ${TMPDIR}/workdir/dem/
  
  dem="$( find ${TMPDIR}/workdir/dem -name "*.dem")"
  [ ! -e ${dem} ] && return ${ERR_NODEM}

  export dem="${dem}"

}


function main() {

  ciop-log "INFO" "Setting the environment for ROI_PAC"
 
  set_env
 
  cat > ${TMPDIR}/input

  get_aux 
  
  get_orbit 

  get_dem || exit $? 

  ciop-log "INFO" "Converting SAR inputs to RAW"
  # get all SAR products
  for input in $( cat ${TMPDIR}/input | grep 'sar=' )
  do
    sar_url=$( echo ${input} | sed "s/^sar=//")

    # get the date in format YYMMDD
    sar_date=$( opensearch-client ${sar_url} startdate | cut -c 3-10 | tr -d "-")
    [ -z "${sar_date}" ] && return ${ERR_SAR_DATE}
    sar_date_short=$( echo ${sar_date} | cut -c 1-4 )

    ciop-log "INFO" "SAR date: ${sar_date} and ${sar_date_short}"

    # get the dataset identifier
    sar_identifier=$( opensearch-client ${sar_url} identifier )
    [ -z "${sar_identifier}" ] && return ${ERR_SAR_IDENTIFIER}
 
    ciop-log "INFO" "SAR identifier: ${sar_identifier}"

    sar_folder=${TMPDIR}/workdir/${sar_date}
    mkdir -p ${sar_folder}

    # get ASAR products
    sar_url=$( opensearch-client ${sar_url} enclosure )
    [ -z "${sar_url}" ] && return ${ERR_SAR_ENCLOSURE}

    sar="$( ciop-copy -o ${sar_folder} ${sar_url} )"
    [ ! -e "${sar}" ] && return ${ERR_SAR}

    cd ${sar_folder}
    ciop-log "INFO" "make_raw_envi.pl ${sar_identifier} DOR ${sar_date}"
    make_raw_envi.pl ${sar_identifier} DOR ${sar_date} 1>&2
    [ $? != 0 ] && return ${ERR_MAKE_RAW} 


    [ ! -e "${roipac_proc}" ] && {
        echo "SarDir1=${sar_date}" > ${roipac_proc}
        intdir="${sar_date}"
        sar1="${sar_date}"
        geodir="geo_${sar_date_short}"
    } || {
        echo "SarDir2=${sar_date}" >> ${roipac_proc}
        intdir=${intdir}-${sar_date}
        sar2="{sar_date}"
        base=${sar1}_${sar2}
        geodir=${geodir}-${sar_date_short}
    }
  done

  ciop-log "INFO" "Conversion of SAR pair to RAW completed"

  ciop-log "INFO" "Generation of ROI_PAC proc file"

  # generate ROI_PAC proc file
  cat >> ${roipac_proc} << EOF
IntDir=int_${intdir}
SimDir=sim_3asec
# new sim for this track at 4rlks
do_sim=yes
GeoDir=${geodir}

# standard pixel ratio for Envisat beam I2
pixel_ratio=5

FilterStrength=0.6
UnwrappedThreshold=0.05

OrbitType=HDR
Rlooks_int=4
Rlooks_unw=4
Rlooks_sim=4

#flattening=topo
flattening=orbit

# run focusing on both scenes at the same time
concurrent_roi=yes

# little-endian DEM
DEM=${dem}
MODEL=NULL
cleanup=no

#unw_method=snaphu_mcf
#unw_method=icu
unw_method=old

EOF

  ciop-log "INFO" "Invoking ROI_PAC process_2pass"

  cd ${TMPDIR}/workdir
  process_2pass.pl ${roipac_proc} 1>&2
  [ $? -ne 0 ] && exit ${ERR_PROCESS2PASS}

  cd int_${intdir}

  [ ! -e filt_${intdir}-sim_HDR_4rlks.int.rsc ] || [ ! -e filt_${intdir}-sim_HDR_4rlks.int ] && return ${ERR_MISSING_OUTPUT}  

  ciop-log "INFO" "Geocoding the wrapped interferogram"
  h=$( cat filt_${intdir}-sim_HDR_4rlks.int.rsc | grep FILE_LENGTH | tr -s " " | cut -d " " -f 2 )
  w=$( cat filt_${intdir}-sim_HDR_4rlks.int.rsc | grep WIDTH | tr -s " " | cut -d " " -f 2 )

  cpx2rmg \
    filt_${intdir}-sim_HDR_4rlks.int \
    filt_${intdir}-sim_HDR_4rlks.int.hgt \
    ${w} \
    ${h}
  
  cp filt_${intdir}-sim_HDR_4rlks.int.rsc filt_${intdir}-sim_HDR_4rlks.int.hgt.rsc
  
  geocode.pl \
    geomap_4rlks.trans \
    filt_${intdir}-sim_HDR_4rlks.int.hgt \
    geo_${intdir}.int

  ciop-log "INFO" "Creating geotif files for interferogram phase and magnitude"
  
  roipac2grdfile \
    -t real \
    -i geo_${intdir}.int \
    -r geo_${intdir}.int.rsc \
    -o geo_${intdir}.int.nc
  
  roipac2grdfile \
    -t real \
    -i geo_${intdir}.unw \
    -r geo_${intdir}.unw.rsc \
    -o geo_${intdir}.unw.nc

  gdal_translate \
    NETCDF:"geo_${intdir}.int.nc":phase \
    geo_${intdir}.int.phase.tif
  
  gdal_translate \
    NETCDF:"geo_${intdir}.int.nc":magnitude \
    geo_${intdir}.int.magnitude.tif
  
  gdal_translate \
    NETCDF:"geo_${intdir}.unw.nc":phase \
    geo_${intdir}.unw.phase.tif

  # create quicklooks
  # rescale
  gdal_translate \
    -scale -10 10 0 255 \
    -ot Byte \
    -of GTiff \
    geo_${intdir}.unw.phase.tif \
    geo_${intdir}.unw.phase.temp.tif
  
  gdal_translate \
    -scale -10 10 0 255 \
    -ot Byte \
    -of PNG \
    geo_${intdir}.unw.phase.tif \
    geo_${intdir}.unw.phase.png
  
  listgeo \
    -tfw \
    geo_${intdir}.unw.phase.tif

  mv geo_${intdir}.unw.phase.tfw geo_${intdir}.unw.phase.pngw

  ciop-log "INFO" "Publishing results"
 
  for result in \
    ${TMPDIR}/workdir/int_${intdir}/geo_${intdir}.unw.phase.png \
    ${TMPDIR}/workdir/int_${intdir}/geo_${intdir}.unw.phase.pngw \
    ${TMPDIR}/workdir/*.proc \
    ${TMPDIR}/workdir/int_${intdir}/*_baseline.rsc \
    ${TMPDIR}/workdir/int_${intdir}/${intdir}-sim*.int \
    ${TMPDIR}/workdir/int_${intdir}/${intdir}-sim*.int.rsc \
    ${TMPDIR}/workdir/int_${intdir}/filt*${intdir}-sim*.int \
    ${TMPDIR}/workdir/int_${intdir}/filt*${intdir}-sim*.int.rsc \
    ${TMPDIR}/workdir/int_${intdir}/filt*${intdir}-sim*.unw \
    ${TMPDIR}/workdir/int_${intdir}/filt*${intdir}-sim*.unw.rsc \
    ${TMPDIR}/workdir/int_${intdir}/log \
    ${TMPDIR}/workdir/int_${intdir}/log1 \
    ${TMPDIR}/workdir/int_${intdir}/geo_${intdir}.int.phase.tif \
    ${TMPDIR}/workdir/int_${intdir}/geo_${intdir}.int.magnitude.tif \
    ${TMPDIR}/workdir/int_${intdir}/geo_${intdir}.unw.phase.tif \
    ${TMPDIR}/workdir/int_${intdir}/$intdir.int \
    ${TMPDIR}/workdir/int_${intdir}/$intdir.int.rsc
  do 
    ciop-publish -m ${result} 
  done

  for file in $( find . -name "${intdir}*.cor" )
  do
    ciop-publish -m ${TMPDIR}/workdir/int_${intdir}/${file}
    ciop-publish -m ${TMPDIR}/workdir/int_${intdir}/${file}.rsc
  done

  cleanup
  ciop-log "INFO" "That's all folks" 
}

function cleanup() {
  rm -fr $UUIDTMP
}

