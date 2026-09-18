"""Private, bounded performance telemetry. Never accepts food or keyboard text."""
import json, math, re, secrets, sqlite3, time
from pathlib import Path
from contextlib import closing
SCREENS = {'food_review','launch','search','scan','diary','meals','goals','meal_builder','plate','plate_search','plate_scan','plate_describe'}
NAMES = {'foreground','background','screen_open','main_thread_delay','input_meal_name','input_draft_name','input_description','meal_suggestions','ai_describe','user_reported_slow','persistence_save','search_local','search_remote','barcode_lookup'}
KEYS = {'id','session','at','build','os','screen','name','milliseconds'}
UUID = re.compile(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$')
def connect(folder):
    folder=Path(folder); folder.mkdir(parents=True,exist_ok=True)
    path=folder/'thistle-performance.sqlite3'
    db=sqlite3.connect(path,timeout=10); db.row_factory=sqlite3.Row
    db.execute('''CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, session TEXT NOT NULL,
        at REAL NOT NULL, build TEXT NOT NULL, os TEXT NOT NULL, screen TEXT NOT NULL,
        name TEXT NOT NULL, milliseconds REAL NOT NULL, received REAL NOT NULL)''')
    db.execute('CREATE INDEX IF NOT EXISTS event_session ON events(session,at)')
    path.chmod(0o600)
    return db

def ingest(folder,payload,authorization):
    token_path=Path(folder)/'thistle-upload-token'
    token=token_path.read_text().strip() if token_path.exists() else ''
    if not token or not secrets.compare_digest(authorization or '', 'Bearer '+token):raise PermissionError('invalid_upload_token')
    if not isinstance(payload,dict) or set(payload)!={'events'} or not isinstance(payload['events'],list) or not 1<=len(payload['events'])<=100:raise ValueError('invalid_batch')
    rows=[]; now=time.time()
    for e in payload['events']:
        if not isinstance(e,dict) or set(e)!=KEYS:raise ValueError('invalid_event_fields')
        if not all(isinstance(e[k],str) for k in ('id','session','build','os','screen','name')):raise ValueError('invalid_event_types')
        if not UUID.fullmatch(e['id']) or not UUID.fullmatch(e['session']):raise ValueError('invalid_id')
        if e['screen'] not in SCREENS or e['name'] not in NAMES:raise ValueError('invalid_event_label')
        if not re.fullmatch(r'[0-9.? ()]{1,60}',e['build']) or not re.fullmatch(r'[0-9.]{1,30}',e['os']):raise ValueError('invalid_version')
        for k in ('at','milliseconds'):
            if type(e[k]) not in (float,int) or not math.isfinite(e[k]):raise ValueError('invalid_timing')
        if not now-30*86400 <= e['at'] <= now+300 or not 0<=e['milliseconds']<=86400000:raise ValueError('timing_out_of_range')
        rows.append(tuple(e[k] for k in ('id','session','at','build','os','screen','name','milliseconds'))+(now,))
    with closing(connect(folder)) as db, db:
        db.executemany('INSERT OR IGNORE INTO events VALUES(?,?,?,?,?,?,?,?,?)',rows)
        db.execute('DELETE FROM events WHERE at<?',(now-30*86400,))
        db.execute('DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY at DESC LIMIT -1 OFFSET 50000)')
    return {'accepted':len(rows)}

def summary(folder,session=None):
    if session and not UUID.fullmatch(session):raise ValueError('invalid_session')
    with closing(connect(folder)) as db, db:
        if session:rows=db.execute('SELECT * FROM events WHERE session=? AND at>? ORDER BY at DESC LIMIT 1000',(session,time.time()-30*86400)).fetchall()
        else:rows=db.execute('SELECT * FROM events WHERE at>? ORDER BY at DESC LIMIT 1000',(time.time()-30*86400,)).fetchall()
    grouped={}
    for row in rows:
        item=grouped.setdefault(row['session'],{'session':row['session'],'build':row['build'],'os':row['os'],'latest':row['at'],'events':0,'max_main_thread_delay_ms':0,'max_input_delay_ms':0,'reported_slow':False,'screens':[]})
        item['events']+=1
        if row['screen'] not in item['screens']:item['screens'].append(row['screen'])
        if row['name']=='main_thread_delay':item['max_main_thread_delay_ms']=max(item['max_main_thread_delay_ms'],round(row['milliseconds'],1))
        if row['name'].startswith('input_'):item['max_input_delay_ms']=max(item['max_input_delay_ms'],round(row['milliseconds'],1))
        if row['name']=='user_reported_slow':item['reported_slow']=True
    result={'sessions':list(grouped.values())[:10],'sample_limit':1000}
    if session:result['events']=[dict(r) for r in rows]
    return result
if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('--state-dir',required=True);p.add_argument('--session')
    a=p.parse_args();print(json.dumps(summary(a.state_dir,a.session),indent=2))
