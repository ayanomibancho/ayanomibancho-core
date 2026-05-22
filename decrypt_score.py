import sys
import json
from base64 import b64decode
from py3rijndael import RijndaelCbc, Pkcs7Padding

def decrypt(score_data_b64, client_hash_b64, iv_b64, osu_version):
    # Construct the decryption key
    key_str = f"osu!-scoreburgr---------{osu_version}"
    key = key_str.encode()
    
    # Ensure key is a valid Rijndael key size (16, 24, or 32 bytes)
    # If the length of key is not 16, 24, or 32, we pad/truncate it
    if len(key) not in (16, 24, 32):
        if len(key) < 16:
            key = key.ljust(16, b'\x00')
        elif len(key) < 24:
            key = key.ljust(24, b'\x00')
        elif len(key) < 32:
            key = key.ljust(32, b'\x00')
        else:
            key = key[:32]
            
    iv = b64decode(iv_b64)
    
    aes = RijndaelCbc(
        key=key,
        iv=iv,
        padding=Pkcs7Padding(32),
        block_size=32,
    )
    
    score_data = aes.decrypt(b64decode(score_data_b64)).decode().split(":")
    client_hash_decoded = aes.decrypt(b64decode(client_hash_b64)).decode()
    return score_data, client_hash_decoded

def main():
    try:
        if len(sys.argv) < 5:
            print(json.dumps({"success": False, "error": "Missing arguments"}))
            return
            
        score_data_b64 = sys.argv[1]
        client_hash_b64 = sys.argv[2]
        iv_b64 = sys.argv[3]
        osu_version = sys.argv[4]
        
        score_data, client_hash_decoded = decrypt(score_data_b64, client_hash_b64, iv_b64, osu_version)
        print(json.dumps({
            "success": True,
            "score_data": score_data,
            "client_hash": client_hash_decoded
        }))
    except Exception as e:
        import traceback
        print(json.dumps({
            "success": False,
            "error": str(e),
            "traceback": traceback.format_exc()
        }))

if __name__ == "__main__":
    main()
