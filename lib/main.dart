import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(MaterialApp(
  debugShowCheckedModeBanner: false,
  home: BluetoothMeshWalkieApp(),
));

class BluetoothMeshWalkieApp extends StatefulWidget {
  @override
  _BluetoothMeshWalkieAppState createState() => _BluetoothMeshWalkieAppState();
}

class _BluetoothMeshWalkieAppState extends State<BluetoothMeshWalkieApp> {
  final Strategy strategy = Strategy.P2P_STAR;
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  String? connectedEndpointId;
  String status = "Disconnected";
  List<String> messages = [];
  TextEditingController msgController = TextEditingController();
  bool isRecording = false;
  String? recordPath;

  @override
  void initState() {
    super.initState();
    requestPermissions();
  }

  void requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.microphone,
    ].request();
  }

  void startHosting() async {
    setState(() => status = "Hosting... Looking for connections");
    try {
      await Nearby().startAdvertising(
        "HostDevice",
        strategy,
        onConnectionInitiated: (id, info) => acceptConn(id),
        onConnectionResult: (id, res) => handleStatus(id, res),
        onDisconnected: (id) => setState(() {
          status = "Disconnected";
          connectedEndpointId = null;
        }),
      );
    } catch (e) {
      setState(() => status = "Host Error: $e");
    }
  }

  void startDiscovering() async {
    setState(() => status = "Searching for nearby devices...");
    try {
      await Nearby().startDiscovery(
        "JoinerDevice",
        strategy,
        onEndpointFound: (id, name, serviceId) {
          Nearby().requestConnection(
            "JoinerDevice",
            id,
            onConnectionInitiated: (id, info) => acceptConn(id),
            onConnectionResult: (id, res) => handleStatus(id, res),
            onDisconnected: (id) => setState(() {
              status = "Disconnected";
              connectedEndpointId = null;
            }),
          );
        },
        onEndpointLost: (id) {},
      );
    } catch (e) {
      setState(() => status = "Discover Error: $e");
    }
  }

  void acceptConn(String id) {
    Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endpointId, payload) async {
        if (payload.type == PayloadType.BYTES) {
          String received = utf8.decode(payload.bytes!);
          if (received.startsWith("VOICE:")) {
            String audioBase64 = received.replaceFirst("VOICE:", "");
            Uint8List audioBytes = base64Decode(audioBase64);
            final tempDir = await getTemporaryDirectory();
            File tempAudio = File('${tempDir.path}/incoming_${DateTime.now().millisecondsSinceEpoch}.m4a');
            await tempAudio.writeAsBytes(audioBytes);
            await _audioPlayer.play(DeviceFileSource(tempAudio.path));
            setState(() => messages.add("🔊 [Voice Message Received]"));
          } else {
            setState(() => messages.add("Friend: $received"));
          }
        }
      },
      onPayloadTransferUpdate: (id, update) {},
    );
  }

  void handleStatus(String id, Status res) {
    if (res == Status.CONNECTED) {
      setState(() {
        connectedEndpointId = id;
        status = "Connected!";
      });
    }
  }

  void sendTextMessage() {
    if (connectedEndpointId != null && msgController.text.isNotEmpty) {
      Nearby().sendBytesPayload(
        connectedEndpointId!,
        Uint8List.fromList(utf8.encode(msgController.text)),
      );
      setState(() => messages.add("Me: ${msgController.text}"));
      msgController.clear();
    }
  }

  void startVoice() async {
    if (await _audioRecorder.hasPermission()) {
      final tempDir = await getTemporaryDirectory();
      recordPath = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: recordPath!);
      setState(() => isRecording = true);
    }
  }

  void stopAndSendVoice() async {
    final path = await _audioRecorder.stop();
    setState(() => isRecording = false);
    if (path != null && connectedEndpointId != null) {
      File audioFile = File(path);
      Uint8List bytes = await audioFile.readAsBytes();
      String base64Audio = base64Encode(bytes);
      Nearby().sendBytesPayload(
        connectedEndpointId!,
        Uint8List.fromList(utf8.encode("VOICE:$base64Audio")),
      );
      setState(() => messages.add("🔊 [Voice Message Sent]"));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Offline Bluetooth PTT")),
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            color: Colors.grey.shade200,
            width: double.infinity,
            child: Text("Status: $status", textAlign: TextAlign.center),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(onPressed: startHosting, child: Text("Host")),
              ElevatedButton(onPressed: startDiscovering, child: Text("Search & Join")),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: messages.length,
              itemBuilder: (context, i) => ListTile(title: Text(messages[i])),
            ),
          ),
          GestureDetector(
            onLongPress: startVoice,
            onLongPressUp: stopAndSendVoice,
            child: Container(
              margin: EdgeInsets.all(8),
              padding: EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              decoration: BoxDecoration(
                color: isRecording ? Colors.red : Colors.green,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mic, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    isRecording ? "Listening... Release to send" : "Hold to Talk (Walkie-Talkie)",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(child: TextField(controller: msgController, decoration: InputDecoration(hintText: "Type text..."))),
                IconButton(icon: Icon(Icons.send), onPressed: sendTextMessage),
              ],
            ),
          )
        ],
      ),
    );
  }
}

