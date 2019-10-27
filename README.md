# ow-fibonacci-bench

##Params for Herodotus
####c) CONFIG_DIR
Path to herodotus.cfg default is current dir

####g) GIT_REV 
Git rev of the function source code to benchmark default is HEAD

`herodotus -c ./config -g HEAD`

##Params for Herodotus
src=path to function

function=name of function entry entry point

reportPath=path to export results data

method=GET

body=body of the request

jmeterDir=path to jmeter executable

jmeterDuration=duration of benchmark

jmeterConfigDir=path to jmx file

jmeterThreads=jmeter concurency

jmeterRampUpDuration=jmeter ramp up duration

sutActionName=name of Open Whisk action

sutRuntime=runtime of SUT example: nodejs:10

sutMemory=amount of memory to allocation

sutTimeout=timeout of faas function

whiskApiHost=URL to Open whisk host

whiskAuth=OpenWhisk authentication token

sloLatencyMs=defined SLO of faas function

deltaLatencyAllowedPercent=delta performance allow to pass the build


