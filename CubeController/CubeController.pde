#include <NewSoftSerial.h>

int prev = 0;

#define MIN_ANALOG_READ 5
#define NUM_SLOTS 4
#define NUM_PHONEMES 11 //Missing one at the mo: d
#define NUM_CARDS 5

// wavesheidl serial pins
#define WAV_TX 2
#define WAV_RX 3
// rfid serial pins
#define RFID_TX 5
#define RFID_RX 4

NewSoftSerial wavSerial(WAV_RX, WAV_TX);
NewSoftSerial rfidSerial(RFID_RX, RFID_TX);

int minValues[] = {
  7, 120, 320, 465, 500, 595, 890, 910, 975, 985, 1000, 1024};
String phonemes[] = {
  "s","a","t","i","p","n","ck","e","h","r","m"}; //,"d"}


byte targetRfids[NUM_CARDS][5] = {
  { 0x03,0x00,0x61,0x45,0x54 },
  { 0x22, 0x00, 0xba, 0x8a, 0x74 },
  { 0x03, 0x00, 0x60, 0x31, 0x44 },
  { 0x03, 0x00, 0x6a, 0x65, 0x65 },
  { 0x03, 0x00, 0x6a, 0x65, 0x62 },
};

String targetStrings[] = {
  "arm",
  "hat",
  "ear",
  "map",
  "tree"
};

String targetWord = NULL;

int slots[NUM_SLOTS];
String slotStrs[NUM_SLOTS];

// RFID reading stuff
byte code[6];

void setup() {
  Serial.begin(9600);

  // define pin modes for wave shield tx, rx:
  pinMode(WAV_RX, INPUT);
  pinMode(WAV_TX, OUTPUT);
  pinMode(RFID_RX, INPUT);
  pinMode(RFID_TX, OUTPUT);
  // set the data rate for the SoftwareSerial port
  wavSerial.begin(9600);
  rfidSerial.begin(9600);
}

void loop() {

  readRfid();


  boolean hasChanged = false;
  for(int i = 0; i < NUM_SLOTS; i++){
    hasChanged |= readCube(i);
  }
  if(hasChanged){
    printCubes();
    checkPhonicsMatchTarget();
  }
  delay(100);
}

void checkPhonicsMatchTarget(){
  if(targetWord == NULL){
    return;
  }
 String current = "";
 for(int i = 0; i < NUM_SLOTS; i++){
   if(slotStrs[i] != NULL){
     current.concat(slotStrs[i]);
   }else{
     current.concat(' ');
   }
 }
 current = current.trim();
 Serial.println(current);
 if(current.equals(targetWord)){
   Serial.println("Congrats! Try another");
 }
}

boolean readCube(int n){
  int an = analogRead(n);
  boolean debounced = false;

  //Special case for empty
  if(an < minValues[0]){
    if(slotStrs[n] != NULL){
      slotStrs[n] = NULL;
      return true;
    }
    else{
      return false;
    }
  }

  for(int p = 0; p < NUM_PHONEMES; p++){
    //We're less than the next phoneme, 
    //we must be the current phoneme as
    // we've ruled out the previous ones
    if(an > minValues[p] && an < minValues[p+1]){
      if(slotStrs[n] != phonemes[p]){
        if(!debounced){
          //something's changed, debounce!
          delay(100);
          //reread
          an = analogRead(n);
          //reset loop
          p = 0;
          debounced = true;
          continue;
        }

        slotStrs[n] = phonemes[p];
        sayPhoneme(n);
        return true;
      }
      continue;
    }
  }

  return false;
}

void sayPhoneme(int slot){
  String str = slotStrs[slot];
  //delay 1/2 sec
  wavSerial.print(";");
  //play wav
  wavSerial.print("*");
  wavSerial.println(str);
  Serial.print("Say: ");
  Serial.println(str);
}

void printCubes(){

  for(int i = 0; i < NUM_SLOTS; i++){
    if(slotStrs[i] == NULL){
      Serial.print("_");
    }
    else{
      Serial.print(slotStrs[i]);
    }
  }
  Serial.println();
}


void readRfid(){
  byte i = 0;
  byte val = 0;
  byte checksum = 0;
  byte tempbyte = 0;
  byte bytesread = 0;

  if(rfidSerial.available() > 0) {
    if((val = rfidSerial.read()) == 2) {                  // check for header 
      while (bytesread < 12) {                        // read 10 digit code + 2 digit checksum
        if( rfidSerial.available() > 0) { 
          val = rfidSerial.read();
          if((val == 0x0D)||(val == 0x0A)||(val == 0x03)||(val == 0x02)) { // if header or stop bytes before the 10 digit reading 
            break;                                    // stop reading
          }

          // Do Ascii/Hex conversion:
          if ((val >= '0') && (val <= '9')) {
            val = val - '0';
          } 
          else if ((val >= 'A') && (val <= 'F')) {
            val = 10 + val - 'A';
          }

          // Every two hex-digits, add byte to code:
          if (bytesread & 1 == 1) {
            // make some space for this hex-digit by
            // shifting the previous hex-digit with 4 bits to the left:
            code[bytesread >> 1] = (val | (tempbyte << 4));

            if (bytesread >> 1 != 5) {                // If we're at the checksum byte,
              checksum ^= code[bytesread >> 1];       // Calculate the checksum... (XOR)
            };
          } 
          else {
            tempbyte = val;                           // Store the first hex digit first...
          };

          bytesread++;                                // ready to read next digit
        } 
      } 

      if (bytesread == 12 && code[5] == checksum) { // if 12 digit read is complete
        rfidChanged();
      }
    }
  }
}

void rfidChanged(){
  for (int i=0; i<5; i++) {
    if (code[i] < 16) Serial.print("0");
    Serial.print(code[i], HEX);
    Serial.print(" ");
  }
  Serial.println();
  
  for(int i = 0; i < NUM_CARDS; i++){
    for(int j = 0; j < 5; j++){
      if(code[j] != targetRfids[i][j]){
        //try the next tag
        j = 5;
        continue;
      }
      if(j == 4){
        targetWord = targetStrings[i];
        //we've got our card!
        Serial.print("target: ");
        Serial.println(targetWord);
        return;
      }
    }
  }

}


