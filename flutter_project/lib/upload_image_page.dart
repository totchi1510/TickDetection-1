import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart';
import 'main.dart';
import 'package:geocoding/geocoding.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class UploadImagePage extends StatefulWidget {
  const UploadImagePage({super.key});

  @override
  State<UploadImagePage> createState() => _UploadImagePageState();
}

class _UploadImagePageState extends State<UploadImagePage> {
  File? _selectedImage;
  final ImagePicker _picker = ImagePicker();
  String place = '';
  String image_url = '';
  double latitude = 0.0;
  double longitude = 0.0;
  late File imageFile;
  late String tick_name;

  Future<String> getPrediction(imageFile) async {
    final url = Uri.parse('http://10.0.2.2:8000/prediction/API/');
    final request = http.MultipartRequest('POST', url);

    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        imageFile.path,
        filename: basename(imageFile.path),
      ),
    );
    try {
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['prediction'];
      } else {
        return 'Error';
      }
    } catch (e) {
      return 'Error';
    }

  }


  Future<void> uploadImage() async {
    final XFile? pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      imageFile = File(pickedFile.path);
      setState(() => _selectedImage = imageFile);
    }
  }

  Future<void> getLatLngFromPlace(String place) async {
    try {
      List<Location> locations = await locationFromAddress(place);
      if (locations.isNotEmpty) {
        final location = locations.first;
        latitude = location.latitude;
        longitude = location.longitude;
      }
    } catch (e) {
      latitude = 0.0;
      longitude = 0.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text('Image Upload Page'),
        centerTitle: true,
      ),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _selectedImage == null
                    ? Container(
                  width: 200,
                  height: 200,
                  color: Colors.grey[300],
                  child: Icon(Icons.image, size: 100, color: Colors.grey[600]),
                )
                    : Image.file(
                  _selectedImage!,
                  height: 200,
                ),
                SizedBox(height: 20),
                ElevatedButton(
                  onPressed: uploadImage,
                  child: Text('Select Image'),
                ),
                SizedBox(height: 20),
                SizedBox(
                  width: screenWidth * 0.8,
                  child: TextFormField(
                    decoration: InputDecoration(
                      labelText: 'Place',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10.0), // 枠線の角の丸みを設定
                      ),
                    ),
                    onChanged: (value) {
                      place = value;
                    },
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Input place';
                      }
                      return null;
                    },
                  ),
                ),
                SizedBox(height: 30),
                ElevatedButton(
                  onPressed: () async{
                    final user = FirebaseAuth.instance.currentUser;
                    try {
                      String fileName = DateTime.now().millisecondsSinceEpoch.toString();
                      Reference storageRef = FirebaseStorage.instance.ref().child("uploads/$fileName.jpg");

                      await storageRef.putFile(imageFile);

                      image_url = await storageRef.getDownloadURL();
                    } catch (e) {
                      image_url = '';
                    }
                    await getLatLngFromPlace(place);
                    tick_name = await getPrediction(imageFile);
                    await FirebaseFirestore.instance.collection('uploads').add({
                      'user_email': user?.email,
                      'image_url': image_url,
                      'place': place,
                      'tick_name': tick_name,
                      'latitude': latitude,
                      'longitude': longitude,
                      'timestamp': FieldValue.serverTimestamp(),
                    });
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) {
                          return MyHomePage(latitude: latitude, longitude: longitude, zoom: 14.0,);
                        },
                        fullscreenDialog: true,
                      ),
                    );
                  },
                  child: Text('Upload'),
                ),
              ],
            ),
          ),
        )
    );
  }
}
