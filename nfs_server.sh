#!/bin/bash

# Script for server side NFS configuration on RHEL 8

package_query() {
    if rpm -q $1 >/dev/null; then
        echo "Package $1 is currently installed, proceeding."
    else
        read -p "Package $1 is not installed, would you like to install it? (y/n) " choice
        while :
        do
            case "$choice" in
                y|Y) dnf -y install "$1"; break;;
                n|N) echo "Package $1 required to continue, exiting..."; exit 1;;
                * ) read -p "Please enter 'y' or 'n': " choice;;
            esac
        done
    fi
    if ! rpm -q $1 >/dev/null; then
        echo "Package $1 failed to install, exiting..."; exit 1
    fi
}

service_query() {
    read -p "WARN: You need start/restart $1 service for the changes to take effect, would you like to continue? (y/n) " choice
    while :
    do
        case "$choice" in
            y|Y ) systemctl restart $1; systemctl enable $1; break;;
            n|N ) echo "ERROR: Give up to start/restart $1 service. Exiting..."; exit 1;;
            * ) read -p "Please enter 'y' or 'n': " choice;;
    esac
    done
}

show_firewall_rules() {
   echo "Activate the firewall service:"
   echo "systemctl restart firewalld"
   echo "systemctl enable firewalld"
   echo "The following services should be opened in your firewall to allow NFS mounts:"
   if [[ $1 != "nfs4" ]]; then
     echo "firewall-cmd --permanent --add-service=rpc-bind"
     echo "firewall-cmd --permanent --add-service=mountd"
   fi
   echo "firewall-cmd --permanent --add-service=nfs"
   echo "The following is a list of ports which should be opened on the firewall:"
   if [[ $nfs_vers_type == "nfs4" ]]; then
     echo "firewall-cmd --permanent --add-port=2049/tcp"
   else
     rpcinfo -p | awk '{if($1 ~ /[[:digit:]]+/){print "firewall-cmd --permanent --add-port=" $4 "/" $3}}' | sort | uniq
   fi
   echo "Reload the above changes for firewall:"
   echo "firewall-cmd --reload"
}

set_firewall_rules() {
   echo "Activate the firewalld service:"
   systemctl restart firewalld
   if [[ "$?" != 0 ]]; then
     echo "Failed to start firewalld service, please make sure firewall service is active(running) before setting rules."
     exit -1;
   else
     echo "success"
   fi
   systemctl enable firewalld
   echo "The following services will be opened in your firewall to allow NFS mounts:"
   if [[ $1 != "nfs4" ]]; then
     echo "firewall-cmd --permanent --add-service=rpc-bind"
     echo "firewall-cmd --permanent --add-service=mountd"
   fi
   echo "firewall-cmd --permanent --add-service=nfs"
   if [[ $1 != "nfs4" ]]; then
     firewall-cmd --permanent --add-service=rpc-bind
     firewall-cmd --permanent --add-service=mountd
   fi
   firewall-cmd --permanent --add-service=nfs
   echo "The following is a list of ports which will be opened on the firewall:"
   if [[ $nfs_vers_type == "nfs4" ]]; then
     echo "firewall-cmd --permanent --add-port=2049/tcp"
     firewall-cmd --permanent --add-port=2049/tcp
   else
     rpcinfo -p | awk '{if($1 ~ /[[:digit:]]+/){print "firewall-cmd --permanent --add-port=" $4 "/" $3}}' | sort | uniq
     rpcinfo -p | awk '{if($1 ~ /[[:digit:]]+/){print "firewall-cmd --permanent --add-port=" $4 "/" $3}}' | sort | uniq | "/bin/bash"
   fi
   echo "Reload the above changes for firewall:"
   firewall-cmd --reload
}

replaceInFile() {
    local search=$1
    local replace=$2
    local replaceFile=$3
    if [[ $(grep -e "${search}" $replaceFile) == "" ]]; then
      echo 1;
    else
      sed -i "s/${search}/${replace}/g" $replaceFile
      echo 0
    fi
}

updateDomainInIdmapdconf(){
    local domain=$1
    if [[ $domain == "" ]]; then
        return 1;
    fi

    local idmapdFile="/etc/idmapd.conf"
    cp $idmapdFile ${idmapdFile}.orginal-"$(date +%Y%m%d%H%M%S)"
    if [[ $(replaceInFile "^Domain=.*$" "Domain=${domain}" $idmapdFile) == 1 ]]; then
        if [[ $(replaceInFile "^#\s*Domain\s*=\s*.*$" "&\nDomain=${domain}" $idmapdFile) == 1 ]]; then
             if [[ $(replaceInFile "^\[General\]$" "&\nDomain=${domain}" $idmapdFile) == 1 ]]; then
                 echo "Domain=${domain}">>$idmapdFile
             fi
        fi
    fi
}


export_array=('/exports') # Array of local filesystems to be exported
remote_array=('*(sync,rw)') # Array of remote client/mount option groupings for a given export
port_array=('32803' '32769' '892' '662' '875') # Array of custom port definitions for NFS/Firewall use
nfs_vers_type=nfs4
nfs_vers=('vers4.2')
nfsv4_domain="lucente.lab"
new_exports=0

if [[ ! -f /etc/exports ]]; then
    touch /etc/exports;
    new_exports=1
else
    for mountpoint in "${export_array[@]}"; do
        if  grep -q "$mountpoint" /etc/exports ; then
            echo "ERROR: Export $mountpoint already configured in exports, exiting to ensure none of your configurations are altered"; exit 1
        fi
    done
fi

if [[ ! -f /etc/nfs.conf ]]; then
    touch /etc/nfs.conf;
fi

package_query net-tools

for newport in "${port_array[@]}"; do
    if  netstat -ltanu | awk '{if($4 ~ /[[:digit:]]+/){print $4}}' | awk -F: '{print $NF}' | sort | uniq | grep "$newport" -wq; then
        echo "ERROR: The port $newport is already being occupied, exiting to ensure none of your configurations are altered"; exit 1
    fi
done

package_query nfs-utils

if [[ $nfs_vers_type != "nfs4" ]]; then
    if nfsconf --isset lockd port ; then
        echo "ERROR: Custom lockd TCP port already configured in /etc/nfs.conf, exiting to ensure your configuration is not altered"; exit 1
    fi
    if nfsconf --isset lockd udp-port ; then
        echo "ERROR: Custom lockd UDP port already configured in /etc/sysctl.conf, exiting to ensure your configuration is not altered"; exit 1
    fi
    if nfsconf --isset statd port ; then
        echo "ERROR: Custom statd ports already configured in /etc/nfs.conf, exiting to ensure your configuration is not altered"; exit 1
    fi
fi

if nfsconf --isset mountd port ; then
    echo "ERROR: Custom mountd ports already configured in /etc/nfs.conf, exiting to ensure your configuration is not altered"; exit 1
fi

for mountpoint in "${export_array[@]}"; do
    if [[ ! -d "$mountpoint" ]]; then
        read -p "ERROR: Local export $mountpoint not found. Would you like to create it? (y/n) " choice
        while :
        do
            case "$choice" in
                y|Y ) mkdir -p "$mountpoint" ; break;;
                n|N ) echo "ERROR: Local export $mountpoint required to continue, exiting..."; exit 1;;
                * ) read -p "Please enter 'y' or 'n': " choice;;
            esac
        done
    fi
done

# NFS server configuration
if [[ $new_exports -eq 0 ]]; then
    cp /etc/exports /etc/exports.orginal-"$(date +%Y%m%d%H%M%S)"
fi

for i in $(seq 0 $(( ${#export_array[@]}-1 ))); do
    cat <<- EOF >>/etc/exports
${export_array[i]}   ${remote_array[i]}
EOF
done

if [[ $nfs_vers_type != "nfs3" ]]; then
    updateDomainInIdmapdconf "$nfsv4_domain"
fi

if [[ $nfs_vers_type != "nfs4" ]]; then
    nfsconf --set lockd port ${port_array[0]}
    nfsconf --set lockd udp-port ${port_array[1]}
    nfsconf --set statd port ${port_array[3]}
fi

nfsconf --set mountd port ${port_array[2]}

all_vers=('vers2' 'vers3' 'vers4' 'vers4.0' 'vers4.1' 'vers4.2')
for nfs_version in "${all_vers[@]}"; do
    nfsconf --set nfsd "$nfs_version" n
done

case $nfs_vers_type in
   nfs4)
       nfsconf --set nfsd vers4 y
       for nfs_version in "${nfs_vers[@]}"; do
           nfsconf --set nfsd "$nfs_version" y
       done
       ;;
   nfs3)
       nfsconf --set nfsd vers3 y
       for nfs_version in "${nfs_vers[@]}"; do
           nfsconf --set nfsd "$nfs_version" y
       done
       ;;
   auto)
       nfsconf --set nfsd vers3 y
       nfsconf --set nfsd vers4 y
       for nfs_version in "${nfs_vers[@]}"; do
           nfsconf --set nfsd "$nfs_version" y
       done
       ;;
   *)
       ;;
esac

if [[ $nfs_vers_type == "nfs4" ]]; then
   echo "Mask NFSv3 service when only NFSv4 is selected."
   systemctl mask --now rpc-statd.service rpcbind.service rpcbind.socket
else
   systemctl unmask --now rpc-statd.service rpcbind.service rpcbind.socket
   service_query rpcbind
fi
service_query nfs-server

read -p "Do you want to set the firewall rules automatically? (y/n) " choice
while :
do
    case "$choice" in
        y|Y )
           set_firewall_rules $nfs_vers_type
           exit 1
           ;;
        n|N )
           show_firewall_rules $nfs_vers_type
           exit 1
           ;;
        * ) read -p "Please enter 'y' or 'n': " choice;;
    esac
done

