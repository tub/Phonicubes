#include <AF_Wave.h>
#include <avr/pgmspace.h>
#include "util.h"
#include "wave.h"


AF_Wave card;
File wavFile=NULL;
Wavefile wave;      // only one!

#define redled 9
#define statusled 8


#define MAX_PLAYLIST 10
struct fat16_dir_entry_struct astPlayList[MAX_PLAYLIST];

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

void setup() {
  Serial.begin(9600);           // set up Serial library at 9600 bps
  Serial.println("Wave test!");


  memset(astPlayList,0, sizeof astPlayList);
  
  pinMode(2, OUTPUT); 
  pinMode(3, OUTPUT);
  pinMode(4, OUTPUT);
  pinMode(5, OUTPUT);
  pinMode(redled, OUTPUT);
  pinMode(statusled, OUTPUT);

  digitalWrite (statusled,LOW);
  if (!card.init_card()) {
    putstring_nl("Card init. failed!"); 
    for(;;)  flashStatusLed(3);

  }
  if (!card.open_partition()) {
    putstring_nl("No partition!"); 
    for(;;)  flashStatusLed(4);
  }
  if (!card.open_filesys()) {
    putstring_nl("Couldn't open filesys"); 
    for(;;)  flashStatusLed(5);
  }
  if (!card.open_rootdir()) {
    putstring_nl("Couldn't open dir"); 
    for(;;)  flashStatusLed(5);
  }
  digitalWrite (statusled,HIGH);
//  ls();
//  playfile(ONEKHZ);

}

#define SZ_FILENAME 10
#define SZ_PLAYLIST 20

byte iPlayCount = 0;

#define SZ_PLAYQUEUE 10
byte playQueue[SZ_PLAYQUEUE];
byte queueHead = 0;
byte queueTail = 0;

int bytesToSkipAtStart = 0;
int bytesToSkipAtEnd = 0;
long delayUntil = 0;

void writePlayQueue(byte value)
{
  byte h = queueHead + 1;
  if(h >= SZ_PLAYQUEUE)
    h = 0;
  if(h == queueTail)
    return;
  playQueue[queueHead] = value;
  queueHead = h;
}
byte readPlayQueue()
{
  if(queueTail == queueHead)
    return 0;
  byte value = playQueue[queueTail];
  if(++queueTail >= SZ_PLAYQUEUE)
    queueTail = 0;
  return value;
}
void clearPlayQueue()
{
  queueTail = 0;
  queueHead = 0;
}

/////////////////////////////////////////////////////////////////////
//
// PARSE PLAYLIST AND CACHE DIRECTORY ENTRY INFO FOR FILES
//
// We actually locate all the files on SD card at this point to 
// save delays while switching between files on playback
//
/////////////////////////////////////////////////////////////////////
byte setupPlaylist(char *szPlayList)
{
  // clear out playlist buffer
  memset(astPlayList,0, sizeof astPlayList);
  iPlayCount = 0;
  byte iPutPos = 0;
  
  Serial.println(szPlayList);
  
  // loop thru the input
  while(iPlayCount < MAX_PLAYLIST)
  {
    // end of data
    if(!*szPlayList)
    {
      // null terminate the last name and get out
      astPlayList[iPlayCount++].long_name[iPutPos] = '\0';      
      break;
    }
    // comma?
    else if(*szPlayList == ',')
    {
      // ensure there was something before comma
      if(iPutPos == 0)
        return 0;
        
      // null-terminate the last name and get ready for next one
      astPlayList[iPlayCount++].long_name[iPutPos] = '\0';
      iPutPos = 0;      
    }
    else if(iPutPos < 8)
    {      
      // store next character of the name
      astPlayList[iPlayCount].long_name[iPutPos++] = toupper(*szPlayList);
    }
    szPlayList++;
  }    
  Serial.println("Searching...");
  
  // counter to work out if all the files in the 
  // playlist were found on the card
  byte iFilesToFind = iPlayCount;
  
  // scan through the directory structure
  struct fat16_dir_entry_struct stFile;  
  while(fat16_read_dir(card.dd, &stFile))
  {    
    // scan through the playlist
    for(byte iCount = 0; iCount < iPlayCount; ++iCount)
    {
      // has this playlist entry been found already?
      if(!astPlayList[iCount].file_size)
      {
        // nope.. compare strings
        char *pch1 = astPlayList[iCount].long_name;
        char *pch2 = stFile.long_name;
        for(;;)
        {          
           // end of first string
           if(!*pch1)
           {
              // also end of second string... or that ends in .WAV?
              if(!*pch2 || 
                (pch2[0] == '.'  && pch2[1] == 'W'  && pch2[2] == 'A'  && pch2[3] == 'V' && pch2[4] == '\0'))
              {
                // we found the file we're looking for
                Serial.println(stFile.long_name);
                memcpy(&astPlayList[iCount], &stFile, sizeof(stFile));
                --iFilesToFind;
              }
              break;
           }
           else if(*pch2!=*pch1)
           {
             break;
           }       
           ++pch1;
           ++pch2;    
        }
      }
      // same file can appear more than once in playlist so need to keep scanning
    }
    
    // can stop the search when all files in the playlist have been found
    if(iFilesToFind <= 0)
      break;
  }
    
  // reset the directory iterator
  fat16_reset_dir(card.dd);
  if(iFilesToFind <= 0)
    return 1;
    
  Serial.println("One or more files could not be found");
  return 0;
}





/////////////////////////////////////////////////////////////////////
//
// CHECK FOR A NEW COMMAND AT SERIAL PORT
//
// +a,b,c    = prepare playlist
// *1*2*3    = play specific files from playlist
// **        = play all files
// ~         = stop playing
// $         = list files
//
/////////////////////////////////////////////////////////////////////
void pollCommands()
{    
  char szPlayList[SZ_PLAYLIST+1];
  int iPutPos = 0;
  if(Serial.available())
  {
    char ch;
    char chCommand = Serial.read();
    switch(chCommand)
    {
      case '+': 
      case '!': 
        digitalWrite (statusled,LOW);
        clearPlayQueue();
        while(iPutPos < SZ_PLAYLIST)
        {
          ch = Serial.read();
          if(ch == -1)
            continue;
          else if('\n' == ch)
            break;
          szPlayList[iPutPos++] = toupper(ch);
        }
        szPlayList[iPutPos++] = '\0';
        setupPlaylist(szPlayList);
        if(chCommand == '!')
        {
          for(int i=0;i<iPlayCount;++i)
             writePlayQueue(i+1);
        }
        digitalWrite (statusled,HIGH);
        break;   
        
       case '*':
         for(;;)
         {
             ch = Serial.read();
             if(ch == -1)             
             {
               continue;
             }
             else if(ch > '0' && ch <= '9')
             {
               writePlayQueue(ch-'0');
             }
             else if(ch >= 'a' && ch <= 'z')
             {
               writePlayQueue(10 + ch-'a');
             }
             else if(ch == '*')
             {
               for(int i=0;i<iPlayCount;++i)
                 writePlayQueue(i+1);
             }
             break;                              
         }
         break;         

       case '~':
         clearPlayQueue();
         delayUntil = 0;
         if(wave.isplaying)
            wave.stop();
         break;
         
       case '(':
          bytesToSkipAtStart = 2000;
          break;
          
       case ')':
          bytesToSkipAtEnd = 2000;
          break;
          
       case '[':
          bytesToSkipAtStart = 0;
          break;
          
       case ']':
          bytesToSkipAtEnd = 0;
          break;

       case ';':
          writePlayQueue(0xff);          
          break;
         
       case '$':
         ls();
         break;
    }  
  }
}

/////////////////////////////////////////////////////////////////////
//
// PROCESSING LOOP
//
/////////////////////////////////////////////////////////////////////
void loop() 
{ 
  // poll for input at the serial port
  pollCommands();
  
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
    
      // check play queue for next thing to play
      byte iPlayPos = readPlayQueue();
      if(iPlayPos == 0xff)
      {
          delayUntil = millis() + 200;
      }
      else if(iPlayPos > 0 && iPlayPos <= iPlayCount)
      {
        // get array index
        --iPlayPos;
               
        // open the new file          
        wavFile = fat16_open_file(card.fs, &astPlayList[iPlayPos]);
        if (!wavFile) 
        {
            Serial.print("Could not open: ");
            Serial.println(astPlayList[iPlayPos].long_name);
        }
        // create wave object
        else if (!wave.create(wavFile)) 
        {
            Serial.print("Invalid WAV file: ");
            Serial.println(astPlayList[iPlayPos].long_name);
        }
        else
        {
            // start the file playing
            Serial.print("Play: ");
            Serial.println(astPlayList[iPlayPos].long_name);
            if(bytesToSkipAtStart>0)
            {
              wave.seek(bytesToSkipAtStart);
            }
            wave.play();
        }                
    }
  }
  else if(bytesToSkipAtEnd > wave.remainingBytesInChunk)
  {
      wave.stop();
  }
  digitalWrite(redled, wave.isplaying);
}


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


