#!/usr/bin/env bash

# --- config

update_interval=1800  # seconds

aqicn_api_token=_PLACEHOLDER_

# city name in pinyin
location=nanjing
# "y"=true; "n"=false
get_location_by_ip_address=y

# script trigger a notification when AQI exceeds the threshold value
notification_threshold=50

# the minimum interval between two notifications in seconds
notification_cooldown=7200

notification_title="AQI on ScreenSaver"

launchd_service_name=com.aheadlead.aqi_on_screensaver


# --- End of config part. Do not modify below this line.

AQI_API_URL=http://api.waqi.info/feed/$location/?token=$aqicn_api_token
LOCATION_API_URL=https://api.waqi.info/mapq/nearest/
LAUNCHAGENTS_PLIST_PATH=~/Library/LaunchAgents/$launchd_service_name.plist
SCREENSAVE_PLIST_PATH=~/Library/Preferences/ByHost/com.apple.ScreenSaver.Basic.plist
LAST_REFRESH_TIME=/tmp/aqi_on_screensaver.last_refresh_time
LAST_NOTIFICATION_TIME=/tmp/aqi_on_screensaver.last_notification_time
LAST_AQI_VALUE=/tmp/aqi_on_screensaver.last_aql_value
LOG=/tmp/aqi_on_screensaver.log
LAST_REFRESH_LOCATION=/tmp/aqi_on_screensaver.last_refresh_location

function _write_config {
    sed -e "s/^$1=.*/$1=$2/" -i "" $0
}

function _install_config_input {
    local _TMP
    prompt=$1
    var_to_set=$2

    echo $prompt
    echo Now: $var_to_set=${!var_to_set}
    read -p "(leaving blank with no change) New: $var_to_set=" _TMP

    if [ ${#_TMP} -ne 0 ];
    then
        _write_config $var_to_set $_TMP
    fi
    echo
}

function _install_config_branch {
    local _TMP
    prompt=$1

    read -p "$prompt (y/n, default: n)" _TMP
    echo

    if [ $_TMP != "y" ];
    then
        return 0
    else
        return 1
    fi
}

function _get_location_by_ip_address {
    payload=$(curl -is $LOCATION_API_URL)
    echo $payload | grep "\"city\":\"" > /dev/null
    if [ $? -eq 0 ];
    then
        location=$(echo $payload | grep -Eo -e '"city":"[^"]+' | cut -d '"' -f4 | tr '[A-Z]' '[a-z]')
        _write_config location $location
        echo $location > $LAST_REFRESH_LOCATION
    else
        echo $(date) Failed to fetch location >> $LOG
    fi
}

function _install_launchagents_plist {
    # get absolute path
    pushd $(dirname $0) > /dev/null
    ABSOLUTE_PATH=$(pwd -P)/$(basename $0)
    popd > /dev/null
    
    PLIST=$(cat <<EOF 
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>Label</key>
        <string>$launchd_service_name</string>
        <key>Program</key>
        <string>$ABSOLUTE_PATH</string>
        <key>StartInterval</key>
        <integer>$update_interval</integer>
        <key>RunAtLoad</key>
        <true/>
        <key>WorkingDirectory</key>
        <string>/tmp</string>
    </dict>
</plist>
EOF
)
    echo + Checking environment
    if [ $(uname -s) != "Darwin" ];
    then
        echo This script cannot be run in your platform, excepted "Darwin" but $(uname -s).
        exit 1
    fi
    echo

    _install_config_input "+ Set your API token you applied from aqicn.org." aqicn_api_token
    _install_config_branch "+ Do you want this script detect your city by IP address?"
    if [ $? -eq 1 ];
    then
        _write_config get_location_by_ip_address y
        _get_location_by_ip_address
        _install_config_branch "+ Here is your city: $location, Right?"
        if [ $? -eq 0 ];
        then
            _write_config get_location_by_ip_address n
            _install_config_input "+ Set the city name which you want aqi-on-screensaver notice you." location
        fi
    else
        _write_config get_location_by_ip_address n
        _install_config_input "+ Set the city name which you want aqi-on-screensaver notice you." location
    fi
    _install_config_input "+ Set the threshold value. If AQI exceeds the value, aqi-screensaver will push a notification." notification_threshold

    echo + Creating launchd services $launchd_service_name
    echo $PLIST > $LAUNCHAGENTS_PLIST_PATH
    echo

    echo + Starting service $launchd_service_name
    pushd $(dirname $LAUNCHAGENTS_PLIST_PATH) > /dev/null
    launchctl load $(basename $LAUNCHAGENTS_PLIST_PATH)
    popd > /dev/null
    echo
}

function _uninstall_launchagents_plist {
    echo + Stopping service $launchd_service_name
    pushd $(dirname $LAUNCHAGENTS_PLIST_PATH) > /dev/null
    launchctl unload $(basename $LAUNCHAGENTS_PLIST_PATH)
    popd > /dev/null
    echo

    echo + Removing launchd service $launchd_service_name
    rm -i $LAUNCHAGENTS_PLIST_PATH
    echo

    echo + Removing temporary files
    rm -i /tmp/aqi_on_screensaver.*
    echo
}    



# Set the title of screensaver
# e.g. _write_screensaver_plist "meiyoubaage"
function _write_screensaver_plist {
    defaults write $SCREENSAVE_PLIST_PATH MESSAGE "$1"
}

# Pop a notification at the right top corner on the screen
# e.g. _pop_notification "Text"
function _pop_notification {
    osascript -e "display notification \"$1\" with title \"$notification_title\""
}



function refresh {
    echo $(date) > $LAST_REFRESH_TIME

    if [ $get_location_by_ip_address = "y" ];
    then
        _TMP=$(cat $LAST_REFRESH_LOCATION)
        _get_location_by_ip_address
        if [ "$_TMP"x != ""x -a "$location" != "$_TMP" ];
        then
            _pop_notification "位置由 $_TMP 变化为 $location"
        fi
    fi

    payload=$(curl -is $AQI_API_URL)
    
    echo $payload | grep "\"status\":\"ok\"" > /dev/null
    if [ $? -ne 0 ];
    then
        echo $(date) Failed to fetch API: $payload >> $LOG
        exit 1
    fi

    aqi_value=$(echo $payload | grep -Eo -e "\"aqi\":[0-9]+" | tail -c +7)
    echo $aqi_value > $LAST_AQI_VALUE
    echo $(date) AQI: $aqi_value >> $LOG

    if [ $aqi_value -gt `expr 2 \* $notification_threshold` ];
    then
        _write_screensaver_plist "AQI: $aqi_value 😫" ;
    elif [ $aqi_value -gt $notification_threshold ];
    then
        _write_screensaver_plist "AQI: $aqi_value 😣" ;
    elif [ $aqi_value -gt 10 ];
    then
        _write_screensaver_plist "AQI: $aqi_value 😁" ;
    else
        _write_screensaver_plist "AQI: $aqi_value 😆🎉" ;
    fi

    if [ $aqi_value -gt $notification_threshold ];
    then
        if [ ! -f $LAST_NOTIFICATION_TIME ]; 
        then 
            echo 0 > $LAST_NOTIFICATION_TIME
        fi
        last_notification_time=$(cat $LAST_NOTIFICATION_TIME)
        if [ $(date +%s) -gt `expr $last_notification_time + $notification_cooldown` ];
        then
            _pop_notification "空气质量恶化，当前 AQI 为 $aqi_value"
            echo $(date +%s) > $LAST_NOTIFICATION_TIME
            echo $(date) Triggered a notification >> $LOG
        else
            echo $(date) The AQI exceeded the threshold level but still waiting for cooldown >> $LOG
        fi
    fi

}


case $1 in
    install)    _install_launchagents_plist ;;
    uninstall)  _uninstall_launchagents_plist ;;
    *)          refresh ;;
esac

