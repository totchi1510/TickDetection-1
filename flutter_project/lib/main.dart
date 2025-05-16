import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'login_page.dart';
import 'regist_user_page.dart';
import 'upload_image_page.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'ask_Gemini_page.dart';

void main() async{
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TickDetection',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(latitude: 35.681236, longitude: 139.767125,),
    );
  }
}

BitmapDescriptor getMarkerColor(String type) {
  switch (type) {
    case 'Amblyomma(Unfed)':
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
    case 'Amblyomma(Blood-fed)':
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueYellow);
    case 'Haemaphysails':
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    case 'Ixodes':
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
    default:
      return BitmapDescriptor.defaultMarker;
  }
}


Future<Set<Marker>> fetchMarkersFromFirestore(
    void Function(String tickName) onTapInfoWindow) async {
  Set<Marker> markers = {};

  final snapshot = await FirebaseFirestore.instance.collection('uploads').get();

  for (var doc in snapshot.docs) {
    final data = doc.data();

    if (data.containsKey('latitude') &&
        data.containsKey('longitude') &&
        data.containsKey('tick_name') &&
        data.containsKey('image_url')) {
      final marker = Marker(
        markerId: MarkerId(doc.id),
        position: LatLng(data['latitude'], data['longitude']),
        icon: getMarkerColor(data['tick_name'] ?? 'default'),
        infoWindow: InfoWindow(
          title: data['tick_name'] ?? 'No Name',
          onTap: () {
            onTapInfoWindow(data['tick_name']);
          },
        ),
      );
      markers.add(marker);
    }
  }
  return markers;
}


class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.latitude,
    required this.longitude,
    this.zoom = 4.5,
  });

  final double latitude;
  final double longitude;
  final double zoom;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  Set<Marker> _markers = {};
  late GoogleMapController mapController;
  void _onMapCreated(GoogleMapController controller) {
    mapController = controller;
  }

  @override
  void initState() {
    super.initState();
    loadMarkers();
  }

  Future<void> loadMarkers() async {
    final markers = await fetchMarkersFromFirestore((tickName) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AskGeminiPage(tick_name: tickName),
          fullscreenDialog: true,
        ),
      );
    });

    setState(() {
      _markers = markers;
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        final user = snapshot.data;
        final LatLng center = LatLng(widget.latitude, widget.longitude);

        return Scaffold(
          appBar: AppBar(
              backgroundColor: Theme
                  .of(context)
                  .colorScheme
                  .inversePrimary,
              title: Text('TickDetectionApp'),
              centerTitle: true,
          ),
          body: GoogleMap(
            onMapCreated: _onMapCreated,
            initialCameraPosition: CameraPosition(
              target: center,
              zoom: widget.zoom,
            ),
            zoomControlsEnabled: true,
            zoomGesturesEnabled: true,
            markers: _markers,
          ),
          drawer: Drawer(
            child: ListView(
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: Icon(Icons.close),
                    onPressed: () {
                      Navigator.pop(context);
                    },
                  ),
                ),
                if (user == null) ...[
                  ListTile(
                    title: const Text('Login'),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) {
                            return LoginPage();
                          },
                          fullscreenDialog: true,
                        ),
                      );
                    },
                  ),
                  ListTile(
                    title: const Text('SignUp'),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) {
                            return RegistUserPage();
                          },
                          fullscreenDialog: true,
                        ),
                      );
                    },
                  ),
                ]
                else
                  ...[
                    ListTile(
                      title: const Text('Upload Image'),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) {
                              return UploadImagePage();
                            },
                            fullscreenDialog: true,
                          ),
                        );
                      },
                    ),
                    ListTile(
                      title: const Text('Logout'),
                      onTap: () async {
                        await FirebaseAuth.instance.signOut();
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ListTile(
                  title: const Text('Ask Gemini'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) {
                          return AskGeminiPage(tick_name: 'None');
                        },
                        fullscreenDialog: true,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
