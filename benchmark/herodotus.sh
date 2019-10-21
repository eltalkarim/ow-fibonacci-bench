#!/usr/bin/env bash

set -e
CONFIG_DIR=$1


while getopts c:r: option
do
case "${option}"
in
c) CONFIG_DIR=${OPTARG};;
esac
done


if [ "X$CONFIG_DIR" == "X" ]
then
  echo no configuration file passed in args set to current dir
  CONFIG_DIR=./
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
GIT_REV=$(git rev-parse HEAD)
cd ${current_dir}
rm -f ${reportPath}/results-${GIT_REV}.csv || true
rm -f ${reportPath}/report-${GIT_REV}.html || true

#run the workload generator
${jmeterDir}/jmeter -n -t ${CONFIG_DIR}${jmeterConfigDir} \
-l ${reportPath}/results-${GIT_REV}.csv \
-Jurl=${API_URL} \
-Jstatus_code_regex="${STATUS_CODE_REGEX}" \
-Jboot_time_regex="${BOOT_TIME_REGEX}" \
-Jvm_id_regex="${VM_ID_REGEX}" \
-Jmemory_regex="${MEMORY_REGEX}" \
-Jtimeout_regex="${TIMEOUT_REGEX}" \
-Jthreads=${jmeterThreads} \
-JrampUpDuration=${jmeterRampUpDuration} \
-Jduration=${jmeterDuration}

LATENCY_DATA=( $(cut -d ',' -f10 ${reportPath}/results-${GIT_REV}.csv ) )
TIMESTAMP_DATA=( $(cut -d ',' -f1 ${reportPath}/results-${GIT_REV}.csv ) )
echo "${LATENCY_DATA[@]}"
for index in ${!LATENCY_DATA[@]}; do
    LATENCY_DATA_STRING+="{y: ${LATENCY_DATA[index]} },"
done

echo $LATENCY_DATA_STRING

AVERAGE_LATENCY=$(awk -F',' '{sum+=$10; ++n} END { print sum/n }' < ${reportPath}/results-${GIT_REV}.csv)


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
		includeZero: false
	},
	data: [{
		type: "line",
		dataPoints: [
		'$LATENCY_DATA_STRING'
		]
	}]
});
chart.render();

}
</script>
</head>
<body>
<div id="chartContainer" style="height: 370px; width: 50%;"></div>
<h2>Average Latency: '$AVERAGE_LATENCY'</h1>
<script src="https://canvasjs.com/assets/script/canvasjs.min.js"></script>
</body>
</html>' > ${reportPath}/report-${GIT_REV}.html

echo benchmarks completed!
