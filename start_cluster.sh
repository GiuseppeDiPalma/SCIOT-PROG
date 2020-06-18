#!/bin/bash

echo ">>>>>>>>START<<<<<<<<"


idImage="ami-07ebfd5b3428b6f4d"
securityGroup="sg-083d0bc639e109568"
instanceType="t2.micro"
keyNameSSH="MiaKeyVM"
subnetId="subnet-02f4dfcc170998f42"
#nameTagSpec="$9"

numSlaveInstance=$2 #number of all instances 
fileToSend=$4

echo "VM Will be launched: $numSlaveInstance"
echo "File send to cluster: $fileToSend"

function helpFunction()
{
   echo "Usage: $0"
   echo -e "\t-c number of SLAVE to run;"
   echo -e "\t-f file to send to cluster;"
   exit 1 # Exit script after printing help
}

while getopts "c:f:" opt
do
   case "$opt" in
      c ) instanceCount="$OPTARG" ;;
      f ) fileSend="$OPTARG" ;;
      ? ) helpFunction ;; # Print helpFunction in case parameter is non-existent
   esac
done

# Print helpFunction in case parameters are empty
if [ -z "$instanceCount" ] || [ -z "$fileSend" ]
then
   echo "Some or all of the parameters are empty";
   helpFunction
fi


function runInstance() {
    aws ec2 run-instances \
        --image-id $idImage \
        --security-group-ids $securityGroup \
        --count 1 \
        --instance-type $instanceType \
        --key-name $keyNameSSH \
        --subnet-id $subnetId \
        --query 'Instances[0].InstanceId' \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value='$1'}]'
}

#Delete previous run file
rm hostfile &> /dev/null
rm runFile &> /dev/null
rm destroy_clusterAWS.sh &> /dev/null
rm configure.sh &>/dev/null
rm master_connect.sh  &>/dev/null
rm run_script.sh &>/dev/null

declare -a ID_vm

#dalla mia macchina virtuale, creo master su AWS e poi gestisco gli slave dal master.

#Creazione master
echo "Creating MASTER!"
while IFS= read -r line
do
    echo "ID VM(master): "$line #qui tengo ID della macchina che ho appena creato del tipo esempio i-02badd859e7be7ac4"
    ID_vm+=( "${line}" )
    echo "#!/bin/bash" >> destroy_clusterAWS.sh
    echo "
rm hostfile &> /dev/null
rm runFile &> /dev/null
rm destroy_clusterAWS.sh &> /dev/null
rm configure.sh &>/dev/null
rm master_connect.sh  &>/dev/null
rm run_script.sh &>/dev/null
    " > destroy_clusterAWS.sh
    echo ""
    echo "#Master" >> destroy_clusterAWS.sh
    echo "aws ec2 terminate-instances --instance-ids "$line >> destroy_clusterAWS.sh
done < <( runInstance MASTER )

#Creazione Slave_N
echo "Starting creation of slaves!"
for (( i=0;i<$numSlaveInstance-1;i++))
do
    echo "Creating slave $((i+1))"
    nameTagSpec="slave_$((i+1))"

    while IFS= read -r line
    do
        echo "ID VM(slave): "$line
        echo ""
        ID_vm+=( "${line}" )
        echo "#Slave" >> destroy_clusterAWS.sh
        echo "aws ec2 terminate-instances --instance-ids "$line >> destroy_clusterAWS.sh
    done < <( runInstance $nameTagSpec )
done 

echo "Sleep 30 seconds  to wait for the creation of the vm on AWS"
sleep 30
#Prendo Indirizzo Pubblico e Privato del master 
echo "Extract Public IP of master for first connection"
masterPublicIp=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=instance-id,Values=${ID_vm[0]}" --query 'Reservations[*].Instances[*].[PublicIpAddress]' --output text)
masterPrivateIp=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=instance-id,Values=${ID_vm[0]}" --query 'Reservations[*].Instances[*].[PrivateIpAddress]' --output text)
numberCoresVMMaster=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=instance-id,Values=${ID_vm[0]}" --query 'Reservations[*].Instances[*].CpuOptions.CoreCount' --output text)
echo "#master" >> runFile
echo $masterPrivateIp" slots="$numberCoresVMMaster "max-slots="$numberCoresVMMaster >> runFile
echo "#slave" >> runFile
#echo "IP PUBBLICO MASTER: " $masterPublicIp
#echo $masterPublicIp"       master">> hostfile

#Prendo Indirizzo Privato degli slave
echo "Add Private IP of slaves in hostfile"
i=0
for id in "${ID_vm[@]:1}"
do
    i=$((i+1));
    slavePrivateIp=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=instance-id,Values=${id}" --query 'Reservations[*].Instances[*].[PrivateIpAddress]' --output text)
    numberCoresVM=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=instance-id,Values=${id}" --query 'Reservations[*].Instances[*].CpuOptions.CoreCount' --output text)
    #echo $slavePrivateIp"       slave_$i">> hostfile
    #echo "numberCoresVM:" $numberCoresVM
    echo $slavePrivateIp" slots="$numberCoresVM "max-slots="$numberCoresVM >> runFile
    echo $slavePrivateIp >> hostfile
    echo 
done

echo "Generating files..."
#This file configure and install openMPI across all machine 
echo "
git clone https://github.com/spagnuolocarmine/ubuntu-openmpi-openmp.git;
source ubuntu-openmpi-openmp/generateInstall.sh;
for host in \$(cat hostfile); do ssh -i ${keyNameSSH}.pem -o \"StrictHostKeyChecking no\" -o \"UserKnownHostsFile=/dev/null\"  ubuntu@\${host} \"bash -s\" 
< install.sh &" > configure.sh
echo "done; bash install.sh; sudo chown pcpc:pcpc hostfile; sudo cp hostfile /home/pcpc;" >> configure.sh

#This script copy all necessary files to master and connect to him with ssh

#echo "scp -i ${keyNameSSH}.pem configure.sh hostfile ${keyNameSSH}.pem $fileToSend ubuntu@${masterPublicIp}:;
#ssh -i ${keyNameSSH}.pem -o \"StrictHostKeyChecking no\" -o \"UserKnownHostsFile=/dev/null\" ubuntu@${masterPublicIp};" > master_connect.sh #create ssh file



#ora nella mia VM lancio master_connect.sh
#mi porta sul master
#poi sul master lancio configure.sh, che prima clona la repo
#dal prof e poi generateInstall.sh sul master, che produce install.sh
#poi sempre configure.sh il master si connette ad ogni slave e lancia il comando install.sh 
#installando l'ambiente di pcpc su ogni slave.

#ora devo scrivere il codice per mandare osu ogni nodo slave, l'eseguibile del programma.

echo "
mpicc ${fileToSend} -o outFiletoexecute

for host in \$(cat hostfile); do scp -i ${keyNameSSH}.pem outFiletoexecute ubuntu@\${host}: done;

" >> run_script.sh

#Invio il file.c al master e poi il master manda eseguibile .out agli slave
echo "Send $fileToSend to master"

scp -i ${keyNameSSH}.pem -o "StrictHostKeyChecking no" -o "UserKnownHostsFile=/dev/null" $fileToSend configure.sh hostfile ${keyNameSSH}.pem runFile run_script.sh ubuntu@${masterPublicIp}:
ssh -i ${keyNameSSH}.pem -o "StrictHostKeyChecking no" -o "UserKnownHostsFile=/dev/null" ubuntu@${masterPublicIp}



echo ">>>>>>>>FINISH<<<<<<<<"