"""Which shapes of each source illustration make up which named part.

A part's shapes are given as numbers (a drawable's place in its prepared file, as label.py shows
them) or as strings (the id of an element or group in the source). A shape can belong to two parts
when one contains the other (the nucleolus is in the nucleus).

`splits` cuts one shape into pieces along a line the artist drew but didn't cut: each piece is
the shape clipped to a region, given as path data in the shape's own coordinates.
"""

OPENSTAX = ('Muscles front and back', 'OpenStax, Tomáš Kebert and umimeto.org', 'CC BY-SA 4.0',
            'https://commons.wikimedia.org/wiki/File:Muscles_front_and_back.svg')

# The line between the deltoid and the chest, as drawn (shape 84), closed off on either side.
_DELTOID_LINE = ('M 15.899551,-185.67366 c 0.51075,-2.67008 1.607185,-5.22653 3.189637,-7.43697 '
                 '2.655729,-3.70964 6.5675,-6.33495 10.630579,-8.40997 4.771339,-2.43673 9.871993,-4.22761 15.119369,-5.30853')
_DELTOID_SIDE = _DELTOID_LINE + ' L 45.35,-240 L -30,-240 L -30,-140 L 15.899551,-140 Z'
_CHEST_SIDE = _DELTOID_LINE + ' L 45.35,-240 L 110,-240 L 110,-140 L 15.899551,-140 Z'

FIGURES = {
    'muscles': {
        'title': 'Muscles, front',
        'height': 460,
        'caption': 'Seen from the front',
        'credit': OPENSTAX,
        'splits': [{'shape': 75, 'pieces': [('deltoid', _DELTOID_SIDE), ('pectoralis', _CHEST_SIDE)]}],
        'parts': {
            'sternocleidomastoid': ('Sternocleidomastoid', [86]),
            'trapezius': ('Trapezius', [68]),
            'deltoid': ('Deltoid', []),                      # a piece of shape 75
            'pectoralis': ('Pectoralis major', [78]),        # and the rest of shape 75
            'biceps': ('Biceps brachii', [82, 83]),
            'brachioradialis': ('Brachioradialis', [81]),
            'forearm': ('Forearm flexors', [70, 72, 73, 74, 79]),
            'abdominis': ('Rectus abdominis (abs)', [87, 88, 89, 90]),
            'oblique': ('External oblique', [67]),
            'sartorius': ('Sartorius', [31]),
            'quadriceps': ('Quadriceps', [21, 24, 28, 32]),
            'adductors': ('Adductors (inner thigh)', [22, 23, 25, 29]),
            'tibialis': ('Tibialis anterior', [13]),
            'calf': ('Gastrocnemius (calf)', [14]),
        },
    },
    'muscles-back': {
        'title': 'Muscles, back',
        'height': 460,
        'caption': 'Seen from behind',
        'credit': OPENSTAX,
        'parts': {
            'trapezius': ('Trapezius', [54, 64, 55]),        # fill, outline, and the pale tendon at its centre
            'deltoid': ('Deltoid', [43]),
            'infraspinatus': ('Infraspinatus', [22]),
            'latissimus': ('Latissimus dorsi', [27, 29]),    # fill and outline
            'triceps': ('Triceps brachii', [40, 41]),
            'gluteus': ('Gluteus maximus', [57, 19]),
            'hamstrings': ('Hamstrings', [12, 13, 11, 8]),
            'calf': ('Gastrocnemius (calf)', [58, 59]),
        },
    },
    'skeleton': {
        'title': 'Skeleton, front',
        'height': 480,
        'caption': 'Seen from the front',
        'credit': ('Human skeleton front, no labels', 'Mariana Ruiz Villarreal (LadyofHats), labels removed by Mikael Häggström',
                   'Public domain', 'https://commons.wikimedia.org/wiki/File:Human_skeleton_front_-_no_labels.svg'),
        'parts': {
            'skull': ('Skull (cranium)', ['Cranium', 'g1297']),
            'mandible': ('Mandible (jaw)', ['Mandible']),
            'clavicle': ('Clavicle (collarbone)', ['ClavicleRight', 'ClavicleLeft']),
            'scapula': ('Scapula (shoulder blade)', ['Scapula']),
            'sternum': ('Sternum (breastbone)', ['Manubrium', 'Sternum', 'path1607']),
            'ribs': ('Ribs (rib cage)', ['g845', 'g1609']),
            'spine': ('Vertebral column (spine)', ['CervicalVertebrae', 'ThoracicVertebrae', 'LumbarVertebrae', 'g801', 'Sacrum', 'Coccyx',
                                                   'path387', 'path389', 'path391', 'path393', 'path395', 'path397', 'path399', 'path401',
                                                   'path403', 'path405', 'path407', 'path639', 'path1115']),
            'humerus': ('Humerus', ['HumerusLeft', 'HumerusRight']),
            'radius': ('Radius', ['RadiusLeft', 'RadiusRight']),
            'ulna': ('Ulna', ['UlnaLeft', 'UlnaRight']),
            'hand': ('Bones of the hand', ['HandLeft', 'HandRight']),
            'pelvis': ('Pelvis (hip bone)', ['PelvicGirdle']),
            'femur': ('Femur (thigh bone)', ['FemurLeft', 'g3760']),
            'patella': ('Patella (kneecap)', ['PatellaRight', 'PatellaLeft']),
            'tibia': ('Tibia (shinbone)', ['TibiaRight', 'TibiaLeft']),
            'fibula': ('Fibula', ['FibulaRight', 'FibulaLeft']),
            'foot': ('Bones of the foot', ['FootLeft', 'FootRight']),
        },
    },
    'heart': {
        'title': 'Heart, opened',
        'height': 380,
        'caption': 'Seen from the front: the patient’s right is on your left',
        'credit': ('Diagram of the human heart (no labels)', 'Wapcaplet, labels removed by Stenemo', 'CC BY-SA 4.0',
                   'https://commons.wikimedia.org/wiki/File:Diagram_of_the_human_heart_(no_labels).svg'),
        'parts': {
            'svc': ('Superior vena cava', ['superior_vena_cava']),
            'ivc': ('Inferior vena cava', ['inferior_vena_cava']),
            'aorta': ('Aorta', ['aorta', 'path597', 'path598', 'g2017', 'ellipse3855', 'ellipse3857', 'g2005']),
            'pulmonary': ('Pulmonary trunk', ['pulmonary_artery_1', 'pulmonary_artery_2', 'g1753', 'g1901']),
            'pulmonary-veins': ('Pulmonary veins', ['pulmonary_vein_1', 'pulmonary_vein_2', 'path602', 'ellipse3849', 'g1759']),
            'ra': ('Right atrium', ['right_atrium', 'path4112']),
            'la': ('Left atrium', ['left_atrium', 'path4354']),
            'rv': ('Right ventricle', ['right_ventricle', 'path4112-4']),
            'lv': ('Left ventricle', ['left_ventricle', 'path4358']),
            'tricuspid': ('Tricuspid valve', ['tricuspid_valve_1', 'tricuspid_valve_2']),
            'mitral': ('Mitral valve', ['mitral_valve_1', 'mitral_valve_2']),
        },
    },
    'brain': {
        'title': 'Brain, from the side',
        'height': 340,
        'caption': 'Seen from the left side: the front of the head is on your left',
        'credit': ('Lobes of the brain', 'Henry Vandyke Carter (Gray’s Anatomy), coloured by Mysid', 'Public domain',
                   'https://commons.wikimedia.org/wiki/File:Lobes_of_the_brain_NL.svg'),
        'parts': {
            'frontal': ('Frontal lobe', [1]),
            'parietal': ('Parietal lobe', [0]),
            'occipital': ('Occipital lobe', [5]),
            'temporal': ('Temporal lobe', [4]),
            'cerebellum': ('Cerebellum', [3]),
            'brainstem': ('Brainstem', [2]),
        },
    },
    'cell': {
        'title': 'Animal cell, cut open',
        'height': 360,
        'caption': None,
        'credit': ('Animal cell structure, no text', 'Mariana Ruiz Villarreal (LadyofHats)', 'Public domain',
                   'https://commons.wikimedia.org/wiki/File:Animal_cell_structure_no_text.svg'),
        'parts': {
            'membrane': ('Cell membrane', [0, 1, 3, 147]),
            'nucleus': ('Nucleus', ['g623', 70]),
            'nucleolus': ('Nucleolus', [43, 70]),
            'er': ('Endoplasmic reticulum', ['g660', 37, 38, 39, 59, 60, 61, 62]),
            'golgi': ('Golgi apparatus', ['g534', 26]),
            'mitochondrion': ('Mitochondrion', ['g442', 'g764']),
            'lysosome': ('Lysosome', [10, 11, 12]),
            'centrosome': ('Centrosome', ['g1044', 'g1180']),
        },
    },
}
