import pyautogui
import time
import sys

def click_load():
    print("Waiting for game window (13s)...")
    
    print("Attempting to click 'Continue'...")
    # Coordinates from logs: (782, 528)
    try:
        x, y = 782, 528
        # Move and click
        pyautogui.moveTo(x, y)
        time.sleep(0.5)
        pyautogui.click()
        print(f"Clicked at {x}, {y}")
        
        # Double tap just in case?
        time.sleep(0.5)
        pyautogui.click()
    except Exception as e:
        print(f"Click failed: {e}")

if __name__ == "__main__":
    click_load()