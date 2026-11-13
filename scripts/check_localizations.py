#!/usr/bin/env python3
"""Check UI translation keys and interpolation placeholders without requiring Xcode."""
import pathlib, re, json, sys
ROOT=pathlib.Path(__file__).resolve().parent.parent
HAN=re.compile('[\u3400-\u9fff]')
class Node:
    pass

def scan(s, start=0, end=None):
    end=len(s) if end is None else end
    nodes=[]; i=start
    while i<end:
        if s.startswith('//',i):
            j=s.find('\n',i); i=end if j<0 else j+1
        elif s.startswith('/*',i):
            depth=1; i+=2
            while depth and i<end:
                if s.startswith('/*',i): depth+=1; i+=2
                elif s.startswith('*/',i): depth-=1; i+=2
                else: i+=1
        elif s[i]=='"' or (s[i]=='#' and re.match(r'#+"',s[i:])):
            node=parse_string(s,i); nodes.append(node); i=node.end
        else: i+=1
    return nodes

def parse_string(s,i):
    n=Node(); n.start=i; n.children=[]; parts=[]; n.args=[]
    hashes=0
    while s[i]=='#': hashes+=1; i+=1
    quote='"""' if s.startswith('"""',i) else '"'
    i+=len(quote); content_start=i; last=i
    close=quote+'#'*hashes; esc='\\'+'#'*hashes
    while i<len(s):
        if s.startswith(close,i):
            parts.append(s[last:i]); i+=len(close); break
        if s.startswith(esc,i):
            j=i+len(esc)
            if s[j:j+1]=='(':
                parts.append(s[last:i]); depth=1; j+=1; expr_start=j
                while depth and j<len(s):
                    if s[j]=='"' or (s[j]=='#' and re.match(r'#+"',s[j:])):
                        child=parse_string(s,j); n.children.append(child); j=child.end
                    elif s.startswith('//',j):
                        k=s.find('\n',j); j=len(s) if k<0 else k+1
                    elif s[j]=='(': depth+=1; j+=1
                    elif s[j]==')': depth-=1; j+=1
                    else: j+=1
                n.args.append(s[expr_start:j-1]); parts.append('{'+str(len(n.args)-1)+'}'); i=j; last=j
            else: i=j+1
        else: i+=1
    n.end=i; n.raw=s[n.start:i]; n.parts=parts; n.hashes=hashes; n.multiline=len(quote)>1
    # Decode the subset of Swift escapes used in UI literals.
    literal=''.join(parts)
    if not hashes:
        literal=re.sub(r'\\u\{([0-9a-fA-F]+)\}',lambda m:chr(int(m[1],16)),literal)
        literal=re.sub(r'\\([0tnr"\\])',lambda m:{'0':'\0','t':'\t','n':'\n','r':'\r','"':'"','\\':'\\'}[m[1]],literal)
    n.key=literal
    return n


def main():
    catalog = json.loads((ROOT / 'Sources/PasteoryCore/Resources/en.json').read_text())
    errors = []
    keys = set()
    for path in (ROOT / 'Sources').rglob('*.swift'):
        source = path.read_text()
        for match in re.finditer(r'\bL10n\.tr\(\s*(?="|\#*"|\#*""")', source):
            node = parse_string(source, match.end())
            keys.add(node.key)
            if node.key not in catalog:
                errors.append(f'{path.relative_to(ROOT)}: Missing English translation: {node.key!r}')
    for key, value in catalog.items():
        if not value or HAN.search(value):
            errors.append(f'Invalid English translation: {key!r}')
        if sorted(re.findall(r'\{\d+\}', key)) != sorted(re.findall(r'\{\d+\}', value)):
            errors.append(f'Mismatched interpolation placeholders: {key!r}')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'Checked {len(keys)} UI templates and {len(catalog)} English translations.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
