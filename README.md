1. data preprocess

2. classification

# Overview

This project performs image classification of tick species using a MobileNetV2 model. Training and evaluation are conducted on Google Colab with data stored in Google Drive.

# 1. Use Google Colab

Run the provided notebook in Google Colab for training and inference.

# 2. Mount Google Drive

To access your dataset and store trained models, mount your Google Drive with:

```python
from google.colab import drive
drive.mount('/content/drive')
```

# 3. Expected File Structure

```
classification/
└── data/
    ├── train/
    │   ├── 1/  # Amblyomma (blood-fed)
    │   ├── 2/  # Amblyomma (non-fed)
    │   ├── 3/  # Haemaphysalis
    │   └── 4/  # Ixodes
    └── val/
        ├── 1/  # Amblyomma (blood-fed)
        ├── 2/  # Amblyomma (non-fed)
        ├── 3/  # Haemaphysalis
        └── 4/  # Ixodes
```

Each class folder should contain images belonging to the respective tick category.

# 4. Trained Model Output

After training, the model will be saved as:

```
classification/
└── saved_model/
    └── model.pth
```

3. Application
   3.1 flutter_project
       You need to install Flutter.
       https://docs.flutter.dev/get-started/install

   3.2 django_prediction_API
     pip install django djangorestframework pillow torch torchvision

   How to run the app
   1. Execute the following comannd.
      cd django_prediction_API
      python manage.py runserver
   2. Start simulator
   3. Start flutter app.

