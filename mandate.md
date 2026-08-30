# remote control a Tizen TV to (1) poweroff (2) poweron then tune to HDMI input
  TV_IP and MAC is known (192.168.86.30 and F8:4E:58:0A:B7:E4)
  wakeonlan to poweron, then send KEY_SOURCE, KEY_DOWN, KEY_DOWN, KEY_OK for (2)
  Just send KEY_POWER for (1)
  e.g. 
  CLIENT_NAME_B64=$(printf '%s' 'User1 local remote' | base64 | tr -d '\n')
  wscat -n -c "wss://$TV_IP:8002/api/v2/channels/samsung.remote.control?name=$CLIENT_NAME_B64" --no-check
  > {"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"KEY_POWER","Option":"false","TypeOfRemote":"SendRemoteKey"}}


