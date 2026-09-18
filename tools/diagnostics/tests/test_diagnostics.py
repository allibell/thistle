import importlib.util, tempfile, unittest, time, uuid
from pathlib import Path
spec=importlib.util.spec_from_file_location('diag',Path(__file__).parents[1]/'thistle_diagnostics.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class DiagnosticsTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);(self.root/'thistle-upload-token').write_text('test-token')
  self.event=dict(id=str(uuid.uuid4()),session=str(uuid.uuid4()),at=time.time(),build='0.1.1 (2026091801)',os='26.0',screen='food_review',name='main_thread_delay',milliseconds=420)
 def tearDown(self):self.tmp.cleanup()
 def send(self,e=None,auth='Bearer test-token'):return m.ingest(self.root,{'events':[e or self.event]},auth)
 def test_auth(self):
  with self.assertRaises(PermissionError):self.send(auth='Bearer admin')
 def test_no_text(self):
  with self.assertRaises(ValueError):self.send(dict(self.event,food='private'))
  with self.assertRaises(ValueError):self.send(dict(self.event,name='typed_private_food'))
 def test_dedup_and_summary(self):
  self.send();self.send();s=m.summary(self.root)['sessions'][0];self.assertEqual(s['events'],1);self.assertEqual(s['max_main_thread_delay_ms'],420)
 def test_timing(self):
  for field,value in [('milliseconds',float('nan')),('at',time.time()-31*86400),('milliseconds',True)]:
   with self.assertRaises(ValueError):self.send(dict(self.event,**{field:value}))
 def test_session_filter(self):
  self.send();self.assertEqual(len(m.summary(self.root,self.event['session'])['events']),1)
  with self.assertRaises(ValueError):m.summary(self.root,"' OR 1=1")
if __name__=='__main__':unittest.main()
