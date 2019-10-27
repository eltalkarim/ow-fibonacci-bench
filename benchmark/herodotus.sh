#!/usr/bin/env bash

set -e
CONFIG_DIR=$1


while getopts c:g: option
do
case "${option}"
in
c) CONFIG_DIR=${OPTARG};;
g) GIT_REV=${OPTARG};;
esac
done


if [ "X$CONFIG_DIR" == "X" ]
then
  echo "no configuration file passed in args set to current directory"
  CONFIG_DIR=./
fi
if [ "X$GIT_REV" == "X" ]
then
  echo "no git revision passed in args set to HEAD"
  GIT_REV=HEAD
fi
cd ${CONFIG_DIR}

#regex expression for response extraction
STATUS_CODE_REGEX="\"statusCode\": \"([^\"]*)\""
VM_ID_REGEX="\"vm_id\": \"([^\"]*)\""
BOOT_TIME_REGEX="\"boot_time\": \"([^\"]*)\""
MEMORY_REGEX="\"memory\": \"([^\"]*)\""
TIMEOUT_REGEX="\"timeout\": \"([^\"]*)\""
#end regex expression

#fetch config
. ${CONFIG_DIR}herodotus.cfg

echo deploying to host ${whiskApiHost}

#delete function of it existed
wsk -i action delete ${sutActionName} || true


#create function
wsk -i action create ${sutActionName} ${src}/${function} \
-t ${sutTimeout} \
-m ${sutMemory} \
--kind ${sutRuntime} \
--apihost ${whiskApiHost} \
--auth ${whiskAuth} \
--web-secure false \
--web true

#fetch function
API_URL=$(wsk -i action get ${sutActionName} --url | awk 'NR==2')

#fetch git rev from source
current_dir=$(pwd)
cd ${src}
git checkout ${GIT_REV}
GIT_REV=$(git rev-parse HEAD)
cd ${current_dir}
rm -f ${reportPath}/results-${GIT_REV}.csv || true
rm -f ${reportPath}/report-${GIT_REV}.html || true

#run the workload generator
echo running bechmarks against ${API_URL}
${jmeterDir}/jmeter -n -t ${CONFIG_DIR}${jmeterConfigDir} \
-l ${reportPath}/${GIT_REV}.csv \
-Jurl=${API_URL} \
-Jstatus_code_regex="${STATUS_CODE_REGEX}" \
-Jboot_time_regex="${BOOT_TIME_REGEX}" \
-Jvm_id_regex="${VM_ID_REGEX}" \
-Jmemory_regex="${MEMORY_REGEX}" \
-Jtimeout_regex="${TIMEOUT_REGEX}" \
-Jthreads=${jmeterThreads} \
-JrampUpDuration=${jmeterRampUpDuration} \
-Jduration=${jmeterDuration}

#sort by timestamp
sort -t, -k1 ${reportPath}/${GIT_REV}.csv > ${reportPath}/results-${GIT_REV}.csv


LATENCY_DATA=( $(cut -d ',' -f10 ${reportPath}/results-${GIT_REV}.csv ) )
TIMESTAMP_DATA=( $(cut -d ',' -f1 ${reportPath}/results-${GIT_REV}.csv ) )
for index in ${!LATENCY_DATA[@]}; do
    X_INDEX="$((${TIMESTAMP_DATA[index]}-${TIMESTAMP_DATA[0]}))"
    LATENCY_DATA_STRING+="{y: ${LATENCY_DATA[index]}},"
done

AVERAGE_LATENCY=$(awk -F',' '{sum+=$10; ++n} END { print sum/n }' < ${reportPath}/results-${GIT_REV}.csv)
MAX_LATENCY=$(awk 'BEGIN { max=0 } $10 > max { max=$10} END { print max }' FS="," < ${reportPath}/results-${GIT_REV}.csv)
MIN_LATENCY=$(awk 'BEGIN { min='${sutTimeout}' } $10 < min { min=$10} END { print min }' FS="," < ${reportPath}/results-${GIT_REV}.csv)
echo MAX is ${MAX_LATENCY}
echo MIN is ${MIN_LATENCY}

Q1_LATENCY=$(sort -t, -k10 ${reportPath}/${GIT_REV}.csv | awk -F',' '{all[NR] = $10} END{print all[int(NR*0.25 -0.5)]}')
Q2_LATENCY=$(sort -t, -k10 ${reportPath}/${GIT_REV}.csv | awk -F',' '{all[NR] = $10} END{print all[int(NR*0.50 -0.5)]}')
Q3_LATENCY=$(sort -t, -k10 ${reportPath}/${GIT_REV}.csv | awk -F',' '{all[NR] = $10} END{print all[int(NR*0.75 -0.5)]}')

rm -f ${reportPath}/${GIT_REV}.csv || true
##### Main

echo '<!DOCTYPE HTML>
<html>
<head>
<script>
window.onload = function () {

var chart = new CanvasJS.Chart("chartContainer", {
	animationEnabled: true,
	theme: "light2",
	title:{
		text: "Performance Benchmarks of version '$GIT_REV'"
	},
	axisY:{
	    title: "Latency in ms",
		includeZero: true
	},
	data: [{
		type: "line",
		dataPoints: [
		'$LATENCY_DATA_STRING'
		]
	}]
});
chart.render();

var chart = new CanvasJS.Chart("chartContainer2", {
	animationEnabled: true,
	axisY: {
		title: "Latency in ms",
		includeZero: true
	},
	data: [{
		type: "boxAndWhisker",
		yValueFormatString: "#000 ms",
		dataPoints: [
			{ x: 0,  y: ['${MIN_LATENCY}', '${Q1_LATENCY}', '${Q3_LATENCY}', '${MAX_LATENCY}', '${Q2_LATENCY}'] },
		]
	}]
});
chart.render();

}
</script>
</head>
<body>
<div id="chartContainer" style="height: 370px; width: 50%;"></div>
<div id="chartContainer2" style="height: 370px; width: 50%"></div>
<p>Average Latency: '$AVERAGE_LATENCY'</p>
<p>Max Latency: '$MAX_LATENCY'</p>
<p>Min Latency: '$MIN_LATENCY'</p>
<script src="https://canvasjs.com/assets/script/canvasjs.min.js"></script>
</body>
</html>' > ${reportPath}/report-${GIT_REV}.html


OVERRIDE=$(awk -F, '$1 !~ '${GIT_REV}'' results/aggregated-results.csv)
echo $OVERRIDE
echo -e "$OVERRIDE \n${GIT_REV},${MIN_LATENCY},${AVERAGE_LATENCY},${Q1_LATENCY},${Q2_LATENCY},${Q3_LATENCY},${MAX_LATENCY}" > ${reportPath}/aggregated-results.csv

echo benchmarks completed!
