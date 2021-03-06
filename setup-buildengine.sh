#!/bin/bash
#
# SDK build engine creation script
#
# Copyright (C) 2014 Jolla Oy
# Contact: Juha Kallioinen <juha.kallioinen@jolla.com>
# All rights reserved.
#
# You may use this file under the terms of BSD license as follows:
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#   * Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#   * Neither the name of the Jolla Ltd nor the
#     names of its contributors may be used to endorse or promote products
#     derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

MYDIR=$(dirname $0)

# some default values
OPT_UPLOAD_HOST=10.0.0.20
OPT_UPLOAD_USER=sdkinstaller
OPT_UPLOAD_PATH=/var/www/sailfishos

# ultra compression by default
OPT_COMPRESSION=9
OPT_TARGET_ARM="Jolla-latest-Sailfish_SDK_Target-armv7hl.tar.bz2"
OPT_TARGET_I486="Jolla-latest-Sailfish_SDK_Target-i486.tar.bz2"
OPT_VM="MerSDK.build"
OPT_VDI=

# some static settings for the VM
SSH_PORT=2222
HTTP_PORT=8080
SAILFISH_DEFAULT_TARGETS="SailfishOS-i486 SailfishOS-armv7hl"

# wrap it all up into this file
PACKAGE_NAME=mersdk.7z

fatal() {
    echo "FAIL: $@"
    exit 1
}

vboxmanage_wrapper() {
    echo "VBoxManage $@"
    VBoxManage "$@"
    [[ $? -ne 0 ]] && fatal "VBoxManage failed"
}

unregisterVm() {
    echo "Unregistering $OPT_VM"
    # make sure the VM is not running
    VBoxManage controlvm "$OPT_VM" poweroff 2>/dev/null
    VBoxManage unregistervm "$OPT_VM" --delete 2>/dev/null
}

createVM() {
    vboxmanage_wrapper createvm --basefolder=$VM_BASEFOLDER --name "$OPT_VM" --ostype Linux26 --register
    vboxmanage_wrapper modifyvm "$OPT_VM" --memory 1024 --vram 128 --accelerate3d off
    vboxmanage_wrapper storagectl "$OPT_VM" --name "SATA" --add sata --controller IntelAHCI $SATACOMMAND 1
    vboxmanage_wrapper storageattach "$OPT_VM" --storagectl SATA --port 0 --type hdd --mtype normal --medium $OPT_VDI
    vboxmanage_wrapper modifyvm "$OPT_VM" --nic1 nat --nictype1 virtio
    vboxmanage_wrapper modifyvm "$OPT_VM" --nic2 intnet --intnet2 sailfishsdk --nictype2 virtio --macaddress2 08005A11F155
    vboxmanage_wrapper modifyvm "$OPT_VM" --bioslogodisplaytime 1
    vboxmanage_wrapper modifyvm "$OPT_VM" --natpf1 "guestssh,tcp,127.0.0.1,${SSH_PORT},,22"
    vboxmanage_wrapper modifyvm "$OPT_VM" --natpf1 "guestwww,tcp,127.0.0.1,${HTTP_PORT},,9292"
    vboxmanage_wrapper modifyvm "$OPT_VM" --natdnshostresolver1 on
}

createShares() {
    # put 'ssh' and 'vmshare' into $SSHCONFIG_PATH
    mkdir -p $SSHCONFIG_PATH/ssh/mersdk
    vboxmanage_wrapper sharedfolder add "$OPT_VM" --name ssh --hostpath $SSHCONFIG_PATH/ssh

    mkdir -p $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine
    pushd $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine
    ssh-keygen -t rsa -N "" -f mersdk
    cp mersdk.pub $SSHCONFIG_PATH/ssh/mersdk/authorized_keys
    popd

    # required for the MerSDK network config
    cat <<EOF > $SSHCONFIG_PATH/vmshare/devices.xml
<?xml version="1.0" encoding="UTF-8"?>
<devices>
    <engine name="MerSDK" type="vbox">
        <subnet>10.220.220</subnet>
    </engine>
</devices>
EOF
    vboxmanage_wrapper sharedfolder add "$OPT_VM" --name config --hostpath $SSHCONFIG_PATH/vmshare

    # and then 'targets' and 'home' for $INSTALL_PATH
    mkdir -p $INSTALL_PATH/targets
    vboxmanage_wrapper sharedfolder add "$OPT_VM" --name targets --hostpath $INSTALL_PATH/targets
    vboxmanage_wrapper sharedfolder add "$OPT_VM" --name home --hostpath $INSTALL_PATH
}

startVM() {
    vboxmanage_wrapper startvm --type headless "$OPT_VM"

    # wait a few seconds
    sleep 2
}

installTarget() {
    # the dumps directory is created outside the VM
    mkdir -p $INSTALL_PATH/dumps

    local tgt=$1

    echo "Installing $tgt to $OPT_VM"
    if [[ -n $(grep i486 <<< $tgt) ]]; then
        TARGET_FILENAME=$OPT_TARGET_I486
        TOOLCHAIN="Mer-SB2-i486"
    else
        TARGET_FILENAME=$OPT_TARGET_ARM
        TOOLCHAIN="Mer-SB2-armv7hl"
    fi

    if [[ ! -f $TARGET_FILENAME ]]; then
        fatal "$TARGET_FILENAME does not exist!"
    fi

    ln $TARGET_FILENAME $INSTALL_PATH/

    echo "Creating target ..."
    ssh -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no \
        -p $SSH_PORT \
        -i $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine/mersdk \
        mersdk@localhost "sdk-manage --target --install --jfdi $tgt $TOOLCHAIN file:///home/mersdk/share/$TARGET_FILENAME"

    echo "Saving target dumps ..."
    ssh -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no \
        -p $SSH_PORT \
        -i $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine/mersdk \
        mersdk@localhost "sb2 -t $tgt qmake -query" > $INSTALL_PATH/dumps/qmake.query.$tgt

    ssh -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no \
        -p $SSH_PORT \
        -i $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine/mersdk mersdk@localhost \
        "sb2 -t $tgt gcc -dumpmachine" > $INSTALL_PATH/dumps/gcc.dumpmachine.$tgt
}

checkVBox() {
    # check that VBox is 4.3 or newer - affects the sataport count.
    VBOX_TOCHECK="4.3"
    echo "Using VirtualBox v$VBOX_VERSION"
    if [[ $(bc <<< "$VBOX_VERSION >= $VBOX_TOCHECK") -eq 1 ]]; then
        SATACOMMAND="--portcount"
    else
        SATACOMMAND="--sataportcount"
    fi
}

initPaths() {
    # anything under this directory will end up in the package
    INSTALL_PATH=$PWD/mersdk
    rm -rf $INSTALL_PATH
    mkdir -p $INSTALL_PATH
    # copy refresh script to an accessible path, this needs to be
    # removed later
    cp -a $MYDIR/refresh-sdk-repos.sh $INSTALL_PATH

    # this is not going to end up inside the package
    SSHCONFIG_PATH=$PWD/sshconfig
    rm -rf $SSHCONFIG_PATH
    mkdir -p $SSHCONFIG_PATH

    # this is not going to end up inside the package
    VM_BASEFOLDER=$PWD/basefolder
    rm -rf $VM_BASEFOLDER
    mkdir -p $VM_BASEFOLDER
}

checkIfVMexists() {
    if [[ -n $(VBoxManage list vms 2>&1 | grep $OPT_VM) ]]; then
        fatal "$OPT_VM already exists. Please unregister it from VirtualBox before proceeding."
    fi
}

checkForRequiredFiles() {
    if [[ ! -f $OPT_VDI ]]; then
        fatal "VDI file [$OPT_VDI] not found in the current directory."
    fi

    if [[ ! -f $OPT_TARGET_ARM ]]; then
        fatal "Target file [$OPT_TARGET_ARM] not found in the current directory."
    fi

    if [[ ! -f $OPT_TARGET_I486 ]]; then
        fatal "Target file [$OPT_TARGET_I486] not found in the current directory."
    fi
}

packVM() {
    echo "Creating 7z package ..."
    # Shut down the VM so it won't interfere (and make sure it's down). This
    # will probably fail because sdk-shutdown has already done its job, so
    # ignore any error output.
    VBoxManage controlvm "$OPT_VM" poweroff 2>/dev/null

    # remove target archive files
    rm -f $INSTALL_PATH/*.tar.bz2

    # remove stuff that is not meant to end up in the package
    rm -f $INSTALL_PATH/.bash_history $INSTALL_PATH/refresh-sdk-repos.sh

    # copy the used VDI file:
    echo "Hard linking $PWD/$OPT_VDI => $INSTALL_PATH/mer.vdi"
    ln $PWD/$OPT_VDI $INSTALL_PATH/mer.vdi

    if [[ ! $OPT_NO_COMPRESSION ]]; then
        # and 7z the mersdk with chosen compression
	7z a -mx=$OPT_COMPRESSION $PACKAGE_NAME $INSTALL_PATH/
    fi
}

checkForRunningVms() {
    local running=$(VBoxManage list runningvms 2>/dev/null)

    if [[ -n $running ]]; then
        echo -n "These virtual machines are running "

        if [[ -n $OPT_IGNORE_RUNNING ]]; then
            echo "[IGNORED]"
        else
            echo "- please stop them before continuing."
        fi

        echo $running

        [[ -n $OPT_IGNORE_RUNNING ]] || exit 1
    fi
}

usage() {
    cat <<EOF
Create $PACKAGE_NAME and optionally upload it to a server.

Usage:
   $(basename $0) -f <VDI> [OPTION]         setup and package the VM
   $(basename $0) unregister [-vm <NAME>]   unregister the VM

Options:
   -u   | --upload <DIR>       upload local build result to [$OPT_UPLOAD_HOST] as user [$OPT_UPLOAD_USER]
                               the uploaded build will be copied to [$OPT_UPLOAD_PATH/<DIR>]
                               the upload directory will be created if it is not there
   -uh  | --uhost <HOST>       override default upload host
   -up  | --upath <PATH>       override default upload path
   -uu  | --uuser <USER>       override default upload user
   -y   | --non-interactive    answer yes to all questions presented by the script
   -f   | --vdi-file <VDI>     use <VDI> file as the virtual disk image [required]
   -i   | --ignore-running     ignore running VMs
   -r   | --refresh            force a zypper refresh for MerSDK and sb2 targets
   -p   | --private            use private rpm repository in 10.0.0.20
   -td  | --test-domain        keep test domain after refreshing the repos
   -o   | --orig-release <REL> turn ssu release to this instead of latest after refreshing repos
   -c   | --compression <0-9>  compression level of 7z [$OPT_COMPRESSION]
   -nc  | --no-compression     do not create the 7z
   -ta  | --target-arm <FILE>  arm target rootstrap <FILE>, must be in current directory
   -ti  | --target-i486 <FILE> i486 target rootstrap <FILE>, must be in current directory
   -un  | --unregister         unregister the created VM at the end of script run
   -hax | --horrible-hack      disable jolla-core.check systemCheck file
   -vm  | --vm-name <NAME>     create VM with <NAME> [$OPT_VM]
   -h   | --help               this help

EOF

    # exit if any argument is given
    [[ -n "$1" ]] && exit 1
}

# BASIC EXECUTION STARTS HERE:

# handle commandline options
while [[ ${1:-} ]]; do
    case "$1" in
        -c | --compression ) shift
            OPT_COMPRESSION=$1; shift
            if [[ $OPT_COMPRESSION != [0123456789] ]]; then
                usage quit
            fi
            ;;
	-nc | --no-compression ) shift
	    OPT_NO_COMPRESSION=1
	    ;;
        -f | --vdi-file ) shift
            OPT_VDI=$1; shift
            ;;
        -ta | --target-arm ) shift
            OPT_TARGET_ARM=$(basename $1); shift
            ;;
        -ti | --target-i486 ) shift
            OPT_TARGET_I486=$(basename $1); shift
            ;;
        -td | --test-domain ) shift
            OPT_KEEP_TEST_DOMAIN="--test-domain"
            ;;
        -i | --ignore-running ) shift
            OPT_IGNORE_RUNNING=1
            ;;
        -hax | --horrible-hack ) shift
            OPT_HACKIT=1
            ;;
        -r | --refresh ) shift
            OPT_REFRESH=1
            ;;
	-p | --private ) shift
	    OPT_PRIVATE_REPO="-p"
	    ;;
	-o | --orig-release ) shift
	    OPT_ORIGINAL_RELEASE=$1; shift
	    [[ -z $OPT_ORIGINAL_RELEASE ]] && fatal "empty original release option given"
	    ;;
        -u | --upload ) shift
            OPT_UPLOAD=1
            OPT_UL_DIR=$1; shift
            if [[ -z $OPT_UL_DIR ]]; then
                fatal "upload option requires a directory name"
            fi
            ;;
        -vm | --vm-name ) shift
            OPT_VM=$1; shift
            ;;
        -uh | --uhost ) shift;
            OPT_UPLOAD_HOST=$1; shift
            ;;
        -up | --upath ) shift;
            OPT_UPLOAD_PATH=$1; shift
            ;;
        -uu | --uuser ) shift;
            OPT_UPLOAD_USER=$1; shift
            ;;
        -h | --help ) shift
            usage quit
            ;;
        -y | --non-interactive ) shift
            OPT_YES=1
            ;;
        -un | --unregister ) shift
            OPT_UNREGISTER=1
            ;;
        unregister ) shift
            OPT_DO_UNREGISTER=1
            ;;
        * )
            usage quit
            ;;
    esac
done

# check if we have VBoxManage
VBOX_VERSION=$(VBoxManage --version 2>/dev/null | cut -f -2 -d '.')
if [[ -z $VBOX_VERSION ]]; then
    fatal "VBoxManage not found."
fi

# handle the explicit unregister case here
if [[ -n $OPT_DO_UNREGISTER ]]; then
    unregisterVm
    exit $?
fi

if [[ -z $OPT_VDI ]]; then
    # Always require a given vdi file
    fatal "VDI file option is required (-f filename.vdi)"
fi

if [[ ${OPT_VDI: -4} == ".bz2" ]]; then
    echo "unpacking $OPT_VDI ..."
    bunzip2 -f -k $OPT_VDI
    OPT_VDI=${OPT_VDI%.bz2}
fi

# get our VDI's formatted filename
OPT_VDI=$(basename $OPT_VDI)

# user can decide to care or not about running vms
checkForRunningVms

# do we have everything..
checkForRequiredFiles

# clear our workarea
initPaths

# some preliminary checks
checkVBox
checkIfVMexists

# all go, let's do it:
cat <<EOF
Creating $OPT_VM, compression=$OPT_COMPRESSION
 MerSDK VDI:  $OPT_VDI
 ARM target:  $OPT_TARGET_ARM
 i486 target: $OPT_TARGET_I486
EOF
if [[ -n $OPT_REFRESH ]]; then
    echo " Force zypper refresh for repos"
    if [[ -n $OPT_PRIVATE_REPO ]]; then
	if [[ -n $OPT_KEEP_TEST_DOMAIN ]]; then
            echo " ... and keep test ssu domain after refresh"
	else
	    echo " ... after update set ssu release to [${OPT_ORIGINAL_RELEASE:-latest}]"
	fi
    fi
else
    echo " Do NOT refresh repos"
fi
if [[ $OPT_NO_COMPRESSION ]]; then
    echo " Do NOT compress the resulting VDI"
fi
if [[ -n $OPT_UPLOAD ]]; then
    echo " Upload build results as user [$OPT_UPLOAD_USER] to [$OPT_UPLOAD_HOST:$OPT_UPLOAD_PATH/$OPT_UL_DIR]"
else
    echo " Do NOT upload build results"
fi

if [[ -n $OPT_HACKIT ]]; then
    echo " ### DO HORRIBLE SYSTEMCHECK HACK!!! ###"
fi

# confirm
if [[ -z $OPT_YES ]]; then
    while true; do
        read -p "Do you want to continue? (y/n) " answer
        case $answer in
            [Yy]*)
                break ;;
            [Nn]*)
                echo "Ok, exiting"
                exit 0
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
fi

# record start time
BUILD_START=$(date +%s)

# set up machine in VirtualBox
createVM
# define the shared directories
createShares
# start the VM
startVM

# install targets to the VM
for targetname in $SAILFISH_DEFAULT_TARGETS; do
    installTarget $targetname
done

if [[ -n $OPT_HACKIT ]]; then
    echo "### EMBARRASSING HACK! CLEANING jolla-core.check!!!"
    ssh -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no \
        -p $SSH_PORT \
        -i $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine/mersdk \
        mersdk@localhost "cat /dev/null | sudo tee /etc/zypp/systemCheck.d/jolla-core.check"
fi

# refresh the zypper repositories
if [[ -n $OPT_REFRESH ]]; then
    ssh -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no \
        -p $SSH_PORT \
        -i $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine/mersdk \
        mersdk@localhost "share/refresh-sdk-repos.sh -y ${OPT_PRIVATE_REPO:-} ${OPT_KEEP_TEST_DOMAIN:-} --release ${OPT_ORIGINAL_RELEASE:-latest}"
fi

# shut the VM down cleanly so that it has time to flush its disk
ssh -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    -p $SSH_PORT \
    -i $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine/mersdk \
    mersdk@localhost "sdk-shutdown"

echo "Giving VM 10 seconds to really shut down ..."
while [[ $(( waitc++ )) -lt 10 ]]; do

    [[ $(VBoxManage list runningvms | grep -c $OPT_VM) -eq 0 ]] && break

    echo "waiting ..."
    sleep 1

    [[ $waitc -ge 10 ]] && echo "WARNING: $OPT_VM did not shut down cleanly!"
done

# wrap it all up into 7z file for installer:
packVM

if [[ -n "$OPT_UPLOAD" ]]; then
    echo "Uploading $PACKAGE_NAME ..."

    # create upload dir
    ssh $OPT_UPLOAD_USER@$OPT_UPLOAD_HOST mkdir -p $OPT_UPLOAD_PATH/$OPT_UL_DIR/
    scp $PACKAGE_NAME $OPT_UPLOAD_USER@$OPT_UPLOAD_HOST:$OPT_UPLOAD_PATH/$OPT_UL_DIR/
fi

if [[ -n $OPT_UNREGISTER ]]; then
    unregisterVm
fi

# record end time
BUILD_END=$(date +%s)

echo "================================="
time=$(( BUILD_END - BUILD_START ))
hour=$(( $time / 3600 ))
mins=$(( $time / 60 - 60*$hour ))
secs=$(( $time - 3600*$hour - 60*$mins ))

echo Time used: $(printf "%02d:%02d:%02d" $hour $mins $secs)
