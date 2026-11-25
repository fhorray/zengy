import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('converter',Path(__file__).with_name('convert_shaders.py'))
converter=importlib.util.module_from_spec(spec);spec.loader.exec_module(converter)
class SplitTests(unittest.TestCase):
    def test_basic(self):
        source='layout(set=2,binding=0) uniform sampler2D color;\nvoid main(){}'
        result,bindings=converter.split_samplers(source)
        self.assertIn('uniform texture2D zengy_color_image;',result)
        self.assertIn('#define color sampler2D(',result)
        self.assertEqual(bindings[0]['sampler_binding'],32)
    def test_collision(self):
        source='layout(set=2,binding=32) uniform X {float a;};\nlayout(set=2,binding=0) uniform sampler2D color;'
        self.assertEqual(converter.split_samplers(source)[1][0]['sampler_binding'],33)
    def test_shadow(self):
        source='layout(binding=3,set=2) uniform sampler2DShadow shadows;'
        result,bindings=converter.split_samplers(source)
        self.assertTrue(bindings[0]['comparison'])
        self.assertIn('sampler2DShadow(',result)
    def test_comments(self):
        source='// layout(set=2,binding=0) uniform sampler2D ignored;\n/* layout(set=2,binding=0) uniform sampler2D ignored; */'
        self.assertEqual(converter.split_samplers(source),(source,[]))
    def test_missing_group(self):
        with self.assertRaises(ValueError):converter.split_samplers('layout(binding=1) uniform sampler2D x;')
    def test_no_samplers(self):
        source='#version 450\nvoid main(){}'
        self.assertEqual(converter.split_samplers(source),(source,[]))
if __name__=='__main__':unittest.main()
