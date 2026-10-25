"""Small adb/UIAutomator helper restricted to one explicitly supplied emulator.
No physical device autodetection, no credential harvesting, no user data reset.
"""
import re
import subprocess
import xml.etree.ElementTree as ET

class EmulatorUi:
    def __init__(self, adb, serial):
        if not isinstance(serial, str) or not re.fullmatch(r'emulator-\d+', serial):
            raise ValueError('Explicit test emulator serial required; never target a physical phone')
        self.adb = str(adb)
        self.serial = serial

    def command(self, *arguments, timeout=20):
        result = subprocess.run([self.adb, '-s', self.serial, *arguments], capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError('adb command failed: ' + ' '.join(arguments[:2]))
        return result.stdout

    def hierarchy(self):
        self.command('shell', 'uiautomator', 'dump', '/data/local/tmp/portlink-test-ui.xml')
        content = self.command('shell', 'cat', '/data/local/tmp/portlink-test-ui.xml')
        return ET.fromstring(content[content.index('<?xml'):])

    def tap_node(self, node):
        bounds = [int(x) for x in re.findall(r'\d+', node.attrib['bounds'])]
        if len(bounds) != 4:
            raise ValueError('Invalid UI bounds')
        self.command('shell', 'input', 'tap', str((bounds[0] + bounds[2]) // 2), str((bounds[1] + bounds[3]) // 2))

    def find(self, text, root=None):
        tree = root if root is not None else self.hierarchy()
        return next((node for node in tree.iter('node') if text in (node.attrib.get('text', '') + '\n' + node.attrib.get('content-desc', ''))), None)

    def tap(self, text):
        node = self.find(text)
        if node is None:
            raise ValueError('UI label not found: ' + text)
        self.tap_node(node)

    def enter_ascii(self, node, value):
        # Only synthetic fixture values, with no shell-control or adb text escape.
        if not re.fullmatch(r'[A-Za-z0-9._:@/-]+', value):
            raise ValueError('Only safe ASCII fixture text allowed')
        self.tap_node(node)
        self.command('shell', 'input', 'keyevent', 'KEYCODE_MOVE_END')
        for _ in range(5):
            self.command('shell', 'input', 'keyevent', *(['KEYCODE_DEL'] * 16))
        self.command('shell', 'input', 'text', value)
