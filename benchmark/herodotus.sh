#!/usr/bin/env bash

set -e

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
GIT_REV_HEAD_1=$(git rev-parse HEAD~1)
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
sort -n -t, -k1 ${reportPath}/${GIT_REV}.csv > ${reportPath}/results-${GIT_REV}.csv

#get latency in array
LATENCY_DATA=( $(cut -d ',' -f10 ${reportPath}/results-${GIT_REV}.csv ) )
TIMESTAMP_DATA=( $(cut -d ',' -f1 ${reportPath}/results-${GIT_REV}.csv ) )
for index in ${!TIMESTAMP_DATA[@]}; do
    X_INDEX="$((${TIMESTAMP_DATA[index]}-${TIMESTAMP_DATA[1]}))"
    LATENCY_DATA_STRING+="{y: ${LATENCY_DATA[index]}},"
done

#calculate statistics
AVERAGE_LATENCY=$(awk -F',' '{sum+=$10; ++n} END { print sum/n }' < ${reportPath}/results-${GIT_REV}.csv)
MAX_LATENCY=$(awk 'BEGIN { max=0 } $10 > max { max=$10} END { print max }' FS="," < ${reportPath}/results-${GIT_REV}.csv)
MIN_LATENCY=$(awk 'BEGIN { min='${sutTimeout}' } $10 < min { min=$10} END { print min }' FS="," < ${reportPath}/results-${GIT_REV}.csv)
Q1_LATENCY=$(sort -n -t, -k10 ${reportPath}/${GIT_REV}.csv | awk -F',' '{all[NR] = $10} END{print all[int(NR*0.25 -0.5)]}')
Q2_LATENCY=$(sort -n -t, -k10 ${reportPath}/${GIT_REV}.csv | awk -F',' '{all[NR] = $10} END{print all[int(NR*0.50 -0.5)]}')
Q3_LATENCY=$(sort -n -t, -k10 ${reportPath}/${GIT_REV}.csv | awk -F',' '{all[NR] = $10} END{print all[int(NR*0.75 -0.5)]}')

rm -f ${reportPath}/${GIT_REV}.csv || true

#aggregration of results
OVERRIDE=$(awk -F, '$1!="'${GIT_REV}'"' ${reportPath}/aggregated-results.csv)
echo -e "${OVERRIDE} \n${GIT_REV},${MIN_LATENCY},${AVERAGE_LATENCY},${Q1_LATENCY},${Q2_LATENCY},${Q3_LATENCY},${MAX_LATENCY}" > ${reportPath}/aggregated-results.csv
AVERAGE_LATENCY_HEAD_1=$(awk -F, '{ if ($1 == "'${GIT_REV_HEAD_1}'") { print $3} }' ${reportPath}/aggregated-results.csv)
DELTA_PERFORMANCE="$((${AVERAGE_LATENCY%.*}-${AVERAGE_LATENCY_HEAD_1%.*}))"
DELTA_PERFORMANCE="$((${DELTA_PERFORMANCE}*100/${AVERAGE_LATENCY_HEAD_1%.*}))"

#get latency in array
AGG_GIT_REV=( $(cut -d ',' -f1 ${reportPath}/aggregated-results.csv ) )
AGG_MIN=( $(cut -d ',' -f2 ${reportPath}/aggregated-results.csv ) )
AGG_AVG=( $(cut -d ',' -f3 ${reportPath}/aggregated-results.csv ) )
AGG_Q1=( $(cut -d ',' -f4 ${reportPath}/aggregated-results.csv ) )
AGG_Q2=( $(cut -d ',' -f5 ${reportPath}/aggregated-results.csv ) )
AGG_Q3=( $(cut -d ',' -f6 ${reportPath}/aggregated-results.csv ) )
AGG_MAX=( $(cut -d ',' -f7 ${reportPath}/aggregated-results.csv ) )
BOX_PLOT=""
for index in ${!AGG_GIT_REV[@]}; do
    BOX_PLOT+="{label: \"${AGG_GIT_REV[index]}\", y: [${AGG_MIN[index]}, ${AGG_Q1[index]}, ${AGG_Q3[index]}, ${AGG_MAX[index]}, ${AGG_Q2[index]}]},"
done

#get status
STATUS="SUCCESS"
if [ $sloLatencyMs -lt ${AVERAGE_LATENCY%.*} ] || [ $DELTA_PERFORMANCE -gt $deltaLatencyAllowedPercent ];
then
  STATUS="FAILURE"
fi

##### Main
echo '<!DOCTYPE HTML>
<html>
<head>
<script>
window.onload = function () {
var chart = new CanvasJS.Chart("chartContainer", {
	animationEnabled: true,
	title:{
		text: "Performance Benchmarks of version '$GIT_REV'"
	},
    axisX: {
		title: "Invocation",
	},
	axisY:{
	    title: "Latency in ms",
		includeZero: true,
        stripLines: [
        {
			value: '$sloLatencyMs',
			label: "SLO",
			color: "red"
		},
		{
            value: '$AVERAGE_LATENCY',
			label: "Average latency"
		}
		]
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
	title:{
		text: "Performance History"
	},
	animationEnabled: true,
	axisY: {
		title: "Latency in ms",
		includeZero: true,
        stripLines: [{
			value: '$sloLatencyMs',
			label: "SLO",
			color: "red"
		}]
	},
    axisX: {
		title: "Version from Git",
		valueFormatString: "#00"
	},
	data: [{
		type: "boxAndWhisker",
		yValueFormatString: "#000 ms",
		xValueFormatString: "#00",
		dataPoints: [
			'$BOX_PLOT'
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
<p>Delta Performance: '$DELTA_PERFORMANCE'%</p>
<p>STATUS: '$STATUS'</p>
<script src="https://canvasjs.com/assets/script/canvasjs.min.js"></script>
</body>
</html>' > ${reportPath}/report-${GIT_REV}.html

#get status

if [ $sloLatencyMs -lt ${AVERAGE_LATENCY%.*} ] || [ $DELTA_PERFORMANCE -gt $deltaLatencyAllowedPercent ];
then
    echo "STATUS: $STATUS" SLO IS NOT MET!
    exit 1
else
    echo "STATUS: $STATUS"
fi

echo benchmarks completed!
