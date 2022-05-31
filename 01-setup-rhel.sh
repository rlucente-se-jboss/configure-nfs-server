#!/usr/bin/env bash

. $(dirname $0)/demo.conf

[[ $EUID -ne 0 ]] && exit_on_error "Must run as root"

##
## register and update the system
##
subscription-manager register \
    --username $USERNAME --password $PASSWORD || exit_on_error "Unable to registrer subscription"
subscription-manager role --set="Red Hat Enterprise Linux Server"
subscription-manager service-level --set="Self-Support"
subscription-manager usage --set="Development/Test"
subscription-manager attach

dnf -y update
dnf -y clean all

##
## configure the web console
##

# install web console
dnf -y install cockpit

# enable web console socket service
systemctl enable --now cockpit.socket

# enable web console access through the firewall
firewall-cmd --add-service=cockpit --permanent
firewall-cmd --reload

##
## configure hostname
##

hostnamectl set-host-name $SERVERNAME

##
## configure insights
##

dnf -y install insights-client

# set credentials in the client configuration file
sed -i.bak 's/^\(#username=\)/\1'$USERNAME'/g' /etc/insights-client/insights-client.conf
sed -i 's/^\(#password=\)/\1'$PASSWORD'/g' /etc/insights-client/insights-client.conf

insights-client --register

