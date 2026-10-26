import 'dart:io';
import 'package:camera/camera.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

class SceneDescriptionService {
  late final GenerativeModel _model;
  
  SceneDescriptionService(String apiKey) {
    _model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: apiKey,
      generationConfig: GenerationConfig(
        temperature: 0.2,
      ),
    );
  }

  Future<String?> describeScene(XFile imageFile, {String? userQuestion}) async {
    try {
      final bytes = await File(imageFile.path).readAsBytes();
      
      String promptText;
      if (userQuestion != null && userQuestion.trim().isNotEmpty) {
        promptText = 'You are a visual assistant for a blind person. '
            'The user asked: "$userQuestion". '
            'Answer this question concisely and accurately based on the image in 1 to 2 short sentences. '
            'Focus on what is immediately in front of the user.';
      } else {
        promptText = 'You are a visual assistant for a blind person navigating outdoors or indoors. '
            'Describe this scene clearly, concisely, and accurately in 1 to 2 short sentences. '
            'Focus on what is immediately in front of the user (e.g., pathways, obstacles, terrain, doors). '
            'Do not describe the sky, camera quality, or things far in the distance unless relevant for navigation. '
            'Example: "I can see a paved pathway in front of you with a grassy garden to your left."';
      }
      
      final prompt = TextPart(promptText);
      
      final imagePart = DataPart('image/jpeg', bytes);
      
      final response = await _model.generateContent([
        Content.multi([prompt, imagePart])
      ]);
      
      return response.text;
    } catch (e) {
      print('Scene description error: $e');
      return 'Sorry, I could not describe the scene right now. Please try again.';
    }
  }
}
