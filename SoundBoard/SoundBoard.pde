//////////////////////////////////////////////////////////////////////////
// 
// PHONICUBE SOUNDBOARD FIRMWARE
//
// Based on Waveshield Code 
//
#include <AF_Wave.h>
#include <avr/pgmspace.h>
#include "util.h"
#include "wave.h"


AF_Wave card;
File wavFile=NULL;
Wavefile wave;      

#define redled 9
#define statusled 8

// This structure is used to pre-cache the directory entries 
// for all the phonics files
struct _DIR_ENTRY {
    char name[2]; // to save space all names are 1 or 2 characters
    uint16_t cluster;
    uint32_t file_size;
    uint32_t entry_offset;
};

// Array in which the directory entries are cached
#define MAX_FILES 50
struct _DIR_ENTRY astFiles[MAX_FILES];
byte iFileCount = 0;

//////////////////////////////////////////////////////////////////////////
//
// FLASH STATUS LED
//
// Used for flashing diagnostic codes on pin 8 led
//
//////////////////////////////////////////////////////////////////////////
void flashStatusLed(int c)
{
  for(int i=0;i<c;++i)
  {
    delay(200);
    digitalWrite(statusled,HIGH);
    delay(200);
    digitalWrite(statusled,LOW);
  }
  delay(500);
}


//////////////////////////////////////////////////////////////////////////
//
// READ FILES
//
// To speed up readiness of the short phonics files for playback, the
// directory descriptors (where on the SD card they live) are all read
// and saved for later. Only files with names that begin with an underscore
// are preloaded. This is a naming convention that must be used for precached 
// files
//
//////////////////////////////////////////////////////////////////////////
byte readFiles()
{
  
  iFileCount = 0;
  Serial.println("Searching...");
  
  // scan through the directory structure
  struct fat16_dir_entry_struct stFile;  
  while(fat16_read_dir(card.dd, &stFile))
  {  
    // starts with underscore?
    if(stFile.long_name[0] == '_')
    {
      // we will cache this one
      Serial.print("Cache ");
      Serial.println(stFile.long_name);
      
      // copy the useful bits of the structure into our array
      astFiles[iFileCount].cluster = stFile.cluster;
      astFiles[iFileCount].file_size = stFile.file_size;
      astFiles[iFileCount].entry_offset = stFile.entry_offset;
      astFiles[iFileCount].name[0] = stFile.long_name[1];
      if(stFile.long_name[2] != '.')
      {
        astFiles[iFileCount].name[1] = stFile.long_name[2];
      }
      else
      {
        astFiles[iFileCount].name[1] = '\0';
      }
      
      // make sure we don't fall off the end
      if(++iFileCount >= MAX_FILES)
        break;
    }
  }
          
  // reset the directory iterator (used in AF_Wave libs)
  fat16_reset_dir(card.dd);
}

//////////////////////////////////////////////////////////////////////////
//
// LS
//
//////////////////////////////////////////////////////////////////////////
void ls() {
  char name[13];
  card.reset_dir();
  putstring_nl("Files found:");
  while (1) {
    if (!card.get_next_name_in_dir(name)) {
       card.reset_dir();
       return;
    }
    Serial.println(name);
  }
}

//////////////////////////////////////////////////////////////////////////
//
// SETUP
//
//////////////////////////////////////////////////////////////////////////
void setup() 
{
  // Serial output is used for diagnostics only
  Serial.begin(9600);           
  Serial.println("Starting...");

  // pin modes...  
  pinMode(2, OUTPUT); 
  pinMode(3, OUTPUT);
  pinMode(4, OUTPUT);
  pinMode(5, OUTPUT);
  pinMode(redled, OUTPUT);
  pinMode(statusled, OUTPUT);

  // status led only lights steady when all init is complete
  digitalWrite (statusled,LOW);
  
  
  if (!card.init_card()) 
  {
    putstring_nl("Card init. failed!"); 
    for(;;) flashStatusLed(3);
  }
  
  if (!card.open_partition()) 
  {
    putstring_nl("No partition!"); 
    for(;;) flashStatusLed(4);
  }
  
  if (!card.open_filesys()) 
  {
    putstring_nl("Couldn't open filesys"); 
    for(;;) flashStatusLed(5);
  }
  
  if (!card.open_rootdir()) 
  {
    putstring_nl("Couldn't open dir"); 
    for(;;) flashStatusLed(5);
  }

  // precache files    
  readFiles();
  
  // and we're done!
  Serial.println("Ready...");
  digitalWrite (statusled,HIGH);
}

/////////////////////////////////////////////////////////////////////
//
//  LOOP
//
/////////////////////////////////////////////////////////////////////
unsigned long delayUntil = 0; // used to implement nonblocking delay
void loop() 
{ 
  // check if a delay is in effect  
  if(millis() < delayUntil)
    return;

  // are we ready to play next file (if any)?    
  if(!wave.isplaying)
  {                
      // ensure the last wav file is closed
      if(wavFile) 
      {
        fat16_close_file(wavFile);
      }
    
      // poll for a command at the serial port
      char ch = Serial.read();
      if(ch == ';')
      {
        // delay
        delayUntil = millis() + 500;
      }
      else if(ch == '$')
      {
        // directory listing
        ls();
      }
      else if(ch == '*')
      {
        // play command.. followed by file name (without underscore or extension) 
        // then a linefeed  
        char szBuffer[12+1];
        byte iPos = 0;
        while(iPos < 8)
        {
          ch = Serial.read();
          if(ch == -1)
            continue; // not ready
          else if(ch == '\n')
            break; // end of command
          else if(ch != '\r')
            szBuffer[iPos++] = toupper(ch); // next char
        }
        szBuffer[iPos] = '\0';
        
        // If the name is 1 or 2 characters then we
        // might have precached it...
        _DIR_ENTRY *pstFile = NULL;
        if(iPos < 3)
        {
          // search the cached file descriptors
          for(byte i = 0; i<iFileCount;++i)
          {
            pstFile = &astFiles[i];
            if(pstFile->name[0] == szBuffer[0] && 
              pstFile->name[1] == szBuffer[1])
            {
              break;
            }
            pstFile = NULL;
          }
        }
        
        // did we find pre-cached file?
        if(pstFile)
        {          
          
          // OK populate the "proper" structure with the 
          // full name
          fat16_dir_entry_struct stFile;
          stFile.attributes = 0;
          stFile.cluster = pstFile->cluster;
          stFile.file_size = pstFile->file_size; 
          stFile.entry_offset = pstFile->entry_offset;
          stFile.long_name[0] = '_';
          stFile.long_name[1] = pstFile->name[0];
          stFile.long_name[2] = pstFile->name[1];
          strcat(stFile.long_name,".WAV");
          
          // open the file          
          wavFile = fat16_open_file(card.fs, &stFile);
          Serial.print("Play cached: ");
          Serial.println(stFile.long_name);
        }
        else
        {
          // we will search for the file in the normal way,
          // scanning from start of directory
          strcat(szBuffer,".WAV");
          wavFile = card.open_file(szBuffer);
          Serial.print("Play: ");
          Serial.println(szBuffer);
        }
        
        // did we open a file?
        if (!wavFile) 
        {
            Serial.print("Could not open: ");
            Serial.println(szBuffer);
        }
        // create wave object
        else if (!wave.create(wavFile)) 
        {
            Serial.print("Invalid WAV file: ");
            Serial.println(szBuffer);
        }
        // start the file playing
        else
        {
            wave.play();
        }                
    }
  }
  
  // update the LED
  digitalWrite(redled, wave.isplaying);
}




