"""Sample app RSS and newly created WebKit processes during the opt-in public-site check."""
import csv
import pathlib
import subprocess
import time

root = pathlib.Path(__file__).resolve().parent.parent
out = root / '.build'
def processes():
    result = {}
    for line in subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,rss=,%cpu=,comm='], text=True).splitlines():
        parts = line.split(None, 4)
        if len(parts) == 5:
            pid, parent, rss, cpu, command = parts
            if 'WebKit' in command or command.endswith('/Slidebox'):
                result[int(pid)] = (int(parent), int(rss), float(cpu), command)
    return result
baseline = processes()
with (out / 'memory-baseline.txt').open('w') as file:
    for pid, values in baseline.items():
        file.write(f'{pid} {values}\n')
with (out / 'memory-check.log').open('w') as log, (out / 'memory-samples.csv').open('w') as file:
    writer = csv.writer(file)
    writer.writerow(['time', 'pid', 'parent', 'rss_kib', 'cpu_percent', 'command'])
    process = subprocess.Popen([str(root / 'dist/Slidebox.app/Contents/MacOS/Slidebox'), '--memory-self-test'], stdout=log, stderr=subprocess.STDOUT)
    while process.poll() is None:
        for pid, values in processes().items():
            if pid == process.pid or pid not in baseline:
                writer.writerow([time.time(), pid, *values])
        file.flush()
        time.sleep(2)
    print(f'memory test exit={process.returncode}; app pid={process.pid}', flush=True)
    raise SystemExit(process.returncode)
