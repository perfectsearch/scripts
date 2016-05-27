#!/bin/sh

if [ "$1" -a -d "$1" ] ; then
    secdir="$1"
    echo "Using $1 as sec directory"
    assecdir=$secdir/../admin-serv
else
    secdir=/etc/dirsrv/slapd-localhost
    assecdir=/etc/dirsrv/admin-serv
fi

if [ "$2" ] ; then
    directorymanager="$2"
else
    directorymanager="cn=Directory Manager"
fi

if [ "$3" ] ; then
    if [[ -f "$3" ]]; then
        dmpwd=$(cat "$3")
    else
        echo "when prompted, provide the directory manager password"
        echo -n "Password:"     
        stty -echo      
        read dmpwd      
        stty echo
    fi
else
    echo "when prompted, provide the directory manager password"
    echo -n "Password:"     
    stty -echo      
    read dmpwd      
    stty echo
fi

if [ "$4" ] ; then
    ldapport=$4
else
    ldapport=389
fi

if [ "$5" ] ; then
    ldapsport=$5
else
    ldapsport=636
fi

me=`whoami`
if [ "$me" = "root" ] ; then
    isroot=1
fi

# see if there are already certs and keys
if [ -f $secdir/cert8.db ] ; then
    # look for CA cert
    if certutil -L -d $secdir -n "CA certificate" 2> /dev/null ; then
        echo "Using existing CA certificate"
    else
        echo "No CA certificate found - will create new one"
        needCA=1
    fi

    # look for server cert
    if certutil -L -d $secdir -n "Server-Cert" 2> /dev/null ; then
        echo "Using existing directory Server-Cert"
    else
        echo "No Server Cert found - will create new one"
        needServerCert=1
    fi

    # look for admin server cert
    if certutil -L -d $assecdir -n "server-cert" 2> /dev/null ; then
        echo "Using existing admin server-cert"
    else
        echo "No Admin Server Cert found - will create new one"
        needASCert=1
    fi
    prefix="new-"
    prefixarg="-P $prefix"
else
    needCA=1
    needServerCert=1
    needASCert=1
fi

if [ -n "$NO_ADMIN" ] ; then
    needASCert=
fi

# get our user and group
if test -n "$isroot" ; then
    uid=`/bin/ls -ald $secdir | awk '{print $3}'`
    gid=`/bin/ls -ald $secdir | awk '{print $4}'`
fi

# 2. Create a password file for your security token password:
if [ -n "$needCA" -o -n "$needServerCert" -o -n "$needASCert" ] ; then
    if [ -f $secdir/pwdfile.txt ] ; then
        echo "Using existing $secdir/pwdfile.txt"
    else
        echo "Creating password file for security token"
        (ps -ef ; w ) | sha1sum | awk '{print $1}' > $secdir/pwdfile.txt
        if test -n "$isroot" ; then
            chown $uid:$gid $secdir/pwdfile.txt
        fi
        chmod 400 $secdir/pwdfile.txt
    fi

# 3. Create a "noise" file for your encryption mechanism:
    if [ -f $secdir/noise.txt ] ; then
        echo "Using existing $secdir/noise.txt file"
    else
        echo "Creating noise file"
        (w ; ps -ef ; date ) | sha1sum | awk '{print $1}' > $secdir/noise.txt
        if test -n "$isroot" ; then
            chown $uid:$gid $secdir/noise.txt
        fi
        chmod 400 $secdir/noise.txt
    fi

# 4. Create the key3.db and cert8.db databases:
    if [ -z "$prefix" ] ; then
        echo "Creating initial key and cert db"
    else
        echo "Creating new key and cert db"
    fi
    certutil -N $prefixarg -d $secdir -f $secdir/pwdfile.txt
    if test -n "$isroot" ; then
        chown $uid:$gid $secdir/${prefix}key3.db $secdir/${prefix}cert8.db
    fi
    chmod 600 $secdir/${prefix}key3.db $secdir/${prefix}cert8.db
fi

getserialno() {
    SERIALNOFILE=${SERIALNOFILE:-$secdir/serialno.txt}
    if [ ! -f $SERIALNOFILE ] ; then
        echo ${BEGINSERIALNO:-1000} > $SERIALNOFILE
    fi
    serialno=`cat $SERIALNOFILE`
    expr $serialno + 1 > $SERIALNOFILE
    echo $serialno
}

if test -n "$needCA" ; then
# 5. Generate the encryption key:
    echo "Creating encryption key for CA"
    certutil -G $prefixarg -d $secdir -z $secdir/noise.txt -f $secdir/pwdfile.txt
# 6. Generate the self-signed certificate:
    echo "Creating self-signed CA certificate"
# note - the basic constraints flag (-2) is required to generate a real CA cert
# it asks 3 questions that cannot be supplied on the command line
    serialno=`getserialno`
    ( echo y ; echo ; echo y ) | certutil -S $prefixarg -n "CA certificate" -s "cn=CAcert" -x -t "CT,," -m $serialno -v 120 -d $secdir -z $secdir/noise.txt -f $secdir/pwdfile.txt -2
# export the CA cert for use with other apps
    echo Exporting the CA certificate to cacert.asc
    certutil -L $prefixarg -d $secdir -n "CA certificate" -a > $secdir/cacert.asc
fi

if test -n "$MYHOST" ; then
    myhost="$MYHOST"
else
    myhost=`hostname --fqdn`
fi

genservercert() {
    hostname=${1:-`hostname --fqdn`}
    certname=${2:-"Server-Cert"}
    serialno=${3:-`getserialno`}
    ou=${OU:-"389 Directory Server"}
    certutil -S $prefixarg -n "$certname" -s "cn=$hostname,ou=$ou" -c "CA certificate" -t "u,u,u" -m $serialno -v 120 -d $secdir -z $secdir/noise.txt -f $secdir/pwdfile.txt
}

remotehost() {
    # the subdir called $host will contain all of the security files to copy to the remote system
    mkdir -p $secdir/$1
    # this is stupid - what we want is that each key/cert db for the remote host has a
    # cert with nickname "Server-Cert" - however, badness:
    # 1) pk12util cannot change nick either during import or export
    # 2) certutil does not have a way to change or rename the nickname
    # 3) certutil cannot create two certs with the same nick
    # so we have to copy all of the secdir files to the new server specific secdir
    # and create everything with copies
    cp -p $secdir/noise.txt $secdir/pwdfile.txt $secdir/cert8.db $secdir/key3.db $secdir/secmod.db $secdir/$1
    SERIALNOFILE=$secdir/serialno.txt secdir=$secdir/$1 genservercert $1
}

if [ -n "$REMOTE" ] ; then
    for host in $myhost ; do
        remotehost $host
    done
elif test -n "$needServerCert" ; then
# 7. Generate the server certificate:
    for host in $myhost ; do
        echo Generating server certificate for 389 Directory Server on host $host
        echo Using fully qualified hostname $host for the server name in the server cert subject DN
        echo Note: If you do not want to use this hostname, export MYHOST="host1 host2 ..." $0 ...
        genservercert $host
    done
fi

if test -n "$needASCert" ; then
# Generate the admin server certificate
    for host in $myhost ; do
        echo Creating the admin server certificate
        OU="389 Administration Server" genservercert $host server-cert
        # export the admin server certificate/private key for import into its key/cert db
        echo Exporting the admin server certificate pk12 file
        pk12util -d $secdir $prefixarg -o $secdir/adminserver.p12 -n server-cert -w $secdir/pwdfile.txt -k $secdir/pwdfile.txt
        if test -n "$isroot" ; then
            chown $uid:$gid $secdir/adminserver.p12
        fi
        chmod 400 $secdir/adminserver.p12
    done
fi

# create the pin file
if [ ! -f $secdir/pin.txt ] ; then
    echo Creating pin file for directory server
    pinfile=$secdir/pin.txt
    echo 'Internal (Software) Token:'`cat $secdir/pwdfile.txt` > $pinfile
    if test -n "$isroot" ; then
        chown $uid:$gid $pinfile
    fi
    chmod 400 $pinfile
else
    echo Using existing $secdir/pin.txt
fi

if [ -n "$REMOTE" ] ; then
    for host in $myhost ; do
        cp -p $secdir/pin.txt $secdir/$host
    done
fi

if [ -n "$needCA" -o -n "$needServerCert" -o -n "$needASCert" ] ; then
    if [ -n "$prefix" ] ; then
    # move the old files out of the way
        mv $secdir/cert8.db $secdir/orig-cert8.db
        mv $secdir/key3.db $secdir/orig-key3.db
    # move in the new files - will be used after server restart
        mv $secdir/${prefix}cert8.db $secdir/cert8.db
        mv $secdir/${prefix}key3.db $secdir/key3.db
    fi
fi

# create the admin server key/cert db
if [ ! -f $assecdir/cert8.db ] ; then
    echo Creating key and cert db for admin server
    certutil -N -d $assecdir -f $secdir/pwdfile.txt
    if test -n "$isroot" ; then
        chown $uid:$gid $assecdir/*.db
    fi
    chmod 600 $assecdir/*.db
fi

if test -n "$needASCert" ; then
# import the admin server key/cert
    echo "Importing the admin server key and cert (created above)"
    pk12util -d $assecdir -n server-cert -i $secdir/adminserver.p12 -w $secdir/pwdfile.txt -k $secdir/pwdfile.txt

# import the CA cert to the admin server cert db
    echo Importing the CA certificate from cacert.asc
    certutil -A -d $assecdir -n "CA certificate" -t "CT,," -a -i $secdir/cacert.asc
    if [ ! -f $assecdir/password.conf ] ; then
# create the admin server password file
        echo Creating the admin server password file
        echo 'internal:'`cat $secdir/pwdfile.txt` > $assecdir/password.conf
        if test -n "$isroot" ; then
            chown $uid:$gid $assecdir/password.conf
        fi
        chmod 400 $assecdir/password.conf
    fi

    if [ -f $assecdir/nss.conf ] ; then
        cd $assecdir
        echo Enabling the use of a password file in admin server
        sed -e "s@^NSSPassPhraseDialog .*@NSSPassPhraseDialog file:`pwd`/password.conf@" nss.conf > /tmp/nss.conf && mv /tmp/nss.conf nss.conf
        if test -n "$isroot" ; then
            chown $uid:$gid nss.conf
        fi
        chmod 400 nss.conf
        echo Turning on NSSEngine
        sed -e "s@^NSSEngine off@NSSEngine on@" console.conf > /tmp/console.conf && mv /tmp/console.conf console.conf
        if test -n "$isroot" ; then
            chown $uid:$gid console.conf
        fi
        chmod 600 console.conf
        echo Use ldaps for config ds connections
        sed -e "s@^ldapurl: ldap://$myhost:$ldapport/o=NetscapeRoot@ldapurl: ldaps://$myhost:$ldapsport/o=NetscapeRoot@" adm.conf > /tmp/adm.conf && mv /tmp/adm.conf adm.conf
        if test -n "$isroot" ; then
            chown $uid:$gid adm.conf
        fi
        chmod 600 adm.conf
        cd $secdir
    fi
fi

# enable SSL in the directory server
echo "Enabling SSL in the directory server"
if [[ -f /opt/search/appliance5/conf/.manager_password ]]; then
    dmpwd=$(cat /opt/search/appliance5/conf/.manager_password)
else
    dmpwd=$(cat /opt/search/appliance5/conf/.ldap_onbox_manager_password)
fi

ldapmodify -x -h localhost -p $ldapport -D "$directorymanager" -w "$dmpwd" <<EOF
dn: cn=encryption,cn=config
changetype: modify
replace: nsSSLClientAuth
nsSSLClientAuth: allowed
-
add: nsSSL3Ciphers
nsSSL3Ciphers: +all

dn: cn=config
changetype: modify
add: nsslapd-security
nsslapd-security: on
-
replace: nsslapd-ssl-check-hostname
nsslapd-ssl-check-hostname: off
-
replace: nsslapd-secureport
nsslapd-secureport: $ldapsport

dn: cn=RSA,cn=encryption,cn=config
changetype: add
objectclass: top
objectclass: nsEncryptionModule
cn: RSA
nsSSLPersonalitySSL: Server-Cert
nsSSLToken: internal (software)
nsSSLActivation: on

EOF

ldapsearch_attrval()
{
    attrname="$1"
    shift
    ldapsearch "$@" $attrname | sed -n '/^'$attrname':/,/^$/ { /^'$attrname':/ { s/^'$attrname': *// ; h ; $ !d}; /^ / { H; $ !d}; /^ /! { x; s/\n //g; p; q}; $ { x; s/\n //g; p; q} }'
}

if [ -n "$needASCert" ] ; then
    echo "Enabling SSL in the admin server"
# find the directory server config entry DN
    dsdn=`ldapsearch_attrval dn -x -LLL -h localhost -p $ldapport -D "$directorymanager" -w "$dmpwd" -b o=netscaperoot "(&(objectClass=nsDirectoryServer)(serverhostname=$myhost)(nsserverport=$ldapport))"`
    ldapmodify -x -h localhost -p $ldapport -D "$directorymanager" -w "$dmpwd" <<EOF
dn: $dsdn
changetype: modify
replace: nsServerSecurity
nsServerSecurity: on
-
replace: nsSecureServerPort
nsSecureServerPort: $ldapsport

EOF

# find the admin server config entry DN
    asdn=`ldapsearch_attrval dn -x -LLL -h localhost -p $ldapport -D "$directorymanager" -w "$dmpwd" -b o=netscaperoot "(&(objectClass=nsAdminServer)(serverhostname=$myhost))"`
    ldapmodify -x -h localhost -p $ldapport -D "$directorymanager" -w "$dmpwd" <<EOF
dn: cn=configuration,$asdn
changetype: modify
replace: nsServerSecurity
nsServerSecurity: on

EOF
fi

echo "Done.  You must restart the directory server and the admin server for the changes to take effect."
restart-dirsrv
