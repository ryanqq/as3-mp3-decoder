/*
Copyright (c) 2008 Christopher Martin-Sperry (audiofx.org@gmail.com)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

package com.gmail.mishonis.gamelib.utils
{
	import flash.display.Loader;
	import flash.display.LoaderInfo;
	import flash.events.ErrorEvent;
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.IOErrorEvent;
	import flash.media.Sound;
	import flash.net.FileReference;
	import flash.net.URLLoader;
	import flash.net.URLLoaderDataFormat;
	import flash.net.URLRequest;
	import flash.utils.ByteArray;
	import flash.utils.Endian;
	

	public class MP3Decoder extends EventDispatcher
	{
		private static var bitRates:Array=[-1,32,40,48,56,64,80,96,112,128,160,192,224,256,320,-1,-1,8,16,24,32,40,48,56,64,80,96,112,128,144,160,-1];
		private static var versions:Array=[2.5,-1,2,1];
		private static var samplingRates:Array=[44100,48000,32000];

		private var _decoding:Boolean;
		private var _sound:Sound;
		private var currentPosition:uint;
		private var sampleRate:uint;
		private var channels:uint;
		private var version:uint;
		
		public function MP3Decoder()
		{
			super();
		}
		

		public function decode(mp3Data:ByteArray):void
		{
			if (decoding) {
				throw new Error('Decoding in progress');
			}

			reset();
			
			_decoding = true;
			
			try {
				currentPosition = getFirstHeaderPosition(mp3Data);
			} catch (err:Error) {
				_decoding = false;
				throw err;
			} 
			
			var swfBytes:ByteArray = getSwfBytes(mp3Data);
			if (!swfBytes) {
				dispatchEvent(new ErrorEvent(ErrorEvent.ERROR));
			} else {
				var swfBytesLoader:Loader=new Loader();
				swfBytesLoader.contentLoaderInfo.addEventListener(Event.COMPLETE,swfCreated);
				swfBytesLoader.loadBytes(swfBytes);
			}
		}

		private function reset():void
		{
			_sound = null;
		}
		
		private function getSwfBytes(mp3Data:ByteArray):ByteArray
		{
			var swfBytes:ByteArray=new ByteArray();
			swfBytes.endian=Endian.LITTLE_ENDIAN;
			for(var i:uint=0;i<SoundClassSwfByteCode.soundClassSwfBytes1.length;++i)
			{
				swfBytes.writeByte(SoundClassSwfByteCode.soundClassSwfBytes1[i]);
			}
			var swfSizePosition:uint=swfBytes.position;
			swfBytes.writeInt(0); //swf size will go here
			for(i=0;i<SoundClassSwfByteCode.soundClassSwfBytes2.length;++i)
			{
				swfBytes.writeByte(SoundClassSwfByteCode.soundClassSwfBytes2[i]);
			}
			var audioSizePosition:uint=swfBytes.position;
			swfBytes.writeInt(0); //audiodatasize+7 to go here
			swfBytes.writeByte(1);
			swfBytes.writeByte(0);
			writeSwfFormatByte(swfBytes);
			
			var sampleSizePosition:uint=swfBytes.position;
			swfBytes.writeInt(0); //number of samples goes here
			
			swfBytes.writeByte(0); //seeksamples
			swfBytes.writeByte(0);
			
			var frameCount:uint=0;
			
			var byteCount:uint=0; //this includes the seeksamples written earlier
			
			for(;;)
			{
				
				var seg:ByteArraySegment=getNextFrame(mp3Data);
				if(seg==null)break;
				swfBytes.writeBytes(seg.byteArray,seg.start,seg.length);
				byteCount+=seg.length;
				frameCount++;
			}
			if(byteCount==0)
			{
				return null;
			}
			byteCount+=2;
			
			var currentPos:uint=swfBytes.position;
			swfBytes.position=audioSizePosition;
			swfBytes.writeInt(byteCount+7);
			swfBytes.position=sampleSizePosition;
			swfBytes.writeInt(frameCount*1152);
			swfBytes.position=currentPos;
			for(i=0;i<SoundClassSwfByteCode.soundClassSwfBytes3.length;++i)
			{
				swfBytes.writeByte(SoundClassSwfByteCode.soundClassSwfBytes3[i]);
			}
			swfBytes.position=swfSizePosition;
			swfBytes.writeInt(swfBytes.length);
			swfBytes.position=0;
			
			return swfBytes;
		}
		
		private function swfCreated(ev:Event):void
		{
			var loaderInfo:LoaderInfo=ev.currentTarget as LoaderInfo;
			var soundClass:Class=loaderInfo.applicationDomain.getDefinition("SoundClass") as Class;
			_sound = new soundClass();
			
			_decoding = false;
			
			dispatchEvent(new Event(Event.COMPLETE));
		}
		
		private function getFirstHeaderPosition(mp3Data:ByteArray):uint
		{
			mp3Data.position=0;
			
			
			while(mp3Data.position<mp3Data.length)
			{
				var readPosition:uint=mp3Data.position;
				var str:String=mp3Data.readMultiByte(3,"us-ascii");
				
				
				if(str=="ID3") //here's an id3v2 header. fuck that for a laugh. skipping
				{
					mp3Data.position+=3;
					var b3:int=(mp3Data.readByte()&0x7F)<<21;
					var b2:int=(mp3Data.readByte()&0x7F)<<14;
					var b1:int=(mp3Data.readByte()&0x7F)<<7;
					var b0:int=mp3Data.readByte()&0x7F;
					var headerLength:int=b0+b1+b2+b3;
					var newPosition:int=mp3Data.position+headerLength;
					trace("Found id3v2 header, length "+headerLength.toString(16)+" bytes. Moving to "+newPosition.toString(16));
					mp3Data.position=newPosition;
					readPosition=newPosition;
				}
				else
				{
					mp3Data.position=readPosition;
				}
				
				var val:uint=mp3Data.readInt();
				
				if(isValidHeader(val))
				{
					parseHeader(val);
					mp3Data.position=readPosition+getFrameSize(val);
					if(isValidHeader(mp3Data.readInt()))
					{
						return readPosition;
					}
					
				}
				
			}
			throw(new Error("Could not locate first header. This isn't an MP3 file"));
		}
		
		private function getNextFrame(mp3Data:ByteArray):ByteArraySegment
		{
			mp3Data.position=currentPosition;
			var headerByte:uint;
			var frameSize:uint;	
			while(true)
			{
				if(currentPosition>(mp3Data.length-4))
				{
					trace("passed eof");
					return null;
				}
				headerByte=mp3Data.readInt();
				if(isValidHeader(headerByte))
				{
					frameSize=getFrameSize(headerByte);
					if(frameSize!=0xffffffff)
					{
						break;
					}
				}
				currentPosition=mp3Data.position;
				
			}
			
			mp3Data.position=currentPosition;
			
			if((currentPosition+frameSize)>mp3Data.length)
			{
				return null;
			}
			
			currentPosition+=frameSize;
			return new ByteArraySegment(mp3Data,mp3Data.position,frameSize);
		}
		
		private function writeSwfFormatByte(byteArray:ByteArray):void
		{
			var sampleRateIndex:uint=4-(44100/sampleRate);
			byteArray.writeByte((2<<4)+(sampleRateIndex<<2)+(1<<1)+(channels-1));
		}
		
		private function parseHeader(headerBytes:uint):void
		{
			var channelMode:uint=getModeIndex(headerBytes);
			version=getVersionIndex(headerBytes);
			var samplingRate:uint=getFrequencyIndex(headerBytes);
			channels=(channelMode>2)?1:2;
			var actualVersion:Number=versions[version];
			var samplingRates:Array=[44100,48000,32000];
			sampleRate=samplingRates[samplingRate];
			switch(actualVersion)
			{
				case 2:
					sampleRate/=2;
					break;
				case 2.5:
					sampleRate/=4;
			}
			
		}
		
		private function getFrameSize(headerBytes:uint):uint
		{
			
			
			var version:uint=getVersionIndex(headerBytes);
			var bitRate:uint=getBitrateIndex(headerBytes);
			var samplingRate:uint=getFrequencyIndex(headerBytes);
			var padding:uint=getPaddingBit(headerBytes);
			var channelMode:uint=getModeIndex(headerBytes);
			var actualVersion:Number=versions[version];
			var sampleRate:uint=samplingRates[samplingRate];
			if(sampleRate!=this.sampleRate||this.version!=version)
			{
				return 0xffffffff;
			}
			switch(actualVersion)
			{
				case 2:
					sampleRate/=2;
					break;
				case 2.5:
					sampleRate/=4;
			}
			var bitRatesYIndex:uint=((actualVersion==1)?0:1)*bitRates.length/2;
			var actualBitRate:uint=bitRates[bitRatesYIndex+bitRate]*1000;			
			var frameLength:uint=(((actualVersion==1?144:72)*actualBitRate)/sampleRate)+padding;
			return frameLength;
			
		}
		
		private function isValidHeader(headerBits:uint):Boolean 
		{
			return (((getFrameSync(headerBits)      & 2047)==2047) &&
				((getVersionIndex(headerBits)   &    3)!=   1) &&
				((getLayerIndex(headerBits)     &    3)!=   0) && 
				((getBitrateIndex(headerBits)   &   15)!=   0) &&
				((getBitrateIndex(headerBits)   &   15)!=  15) &&
				((getFrequencyIndex(headerBits) &    3)!=   3) &&
				((getEmphasisIndex(headerBits)  &    3)!=   2)    );
		}
		
		private function getFrameSync(headerBits:uint):uint     
		{
			return uint((headerBits>>21) & 2047); 
		}
		
		private function getVersionIndex(headerBits:uint):uint  
		{ 
			return uint((headerBits>>19) & 3);  
		}
		
		private function getLayerIndex(headerBits:uint):uint    
		{ 
			return uint((headerBits>>17) & 3);  
		}
		
		private function getBitrateIndex(headerBits:uint):uint  
		{ 
			return uint((headerBits>>12) & 15); 
		}
		
		private function getFrequencyIndex(headerBits:uint):uint
		{ 
			return uint((headerBits>>10) & 3);  
		}
		
		private function getPaddingBit(headerBits:uint):uint    
		{ 
			return uint((headerBits>>9) & 1);  
		}
		
		private function getModeIndex(headerBits:uint):uint     
		{ 
			return uint((headerBits>>6) & 3);  
		}
		
		private function getEmphasisIndex(headerBits:uint):uint
		{ 
			return uint(headerBits & 3);  
		}

		public function get sound():Sound
		{
			return _sound;
		}
		
		public function get decoding():Boolean
		{
			return _decoding;
		}
	}
}

import flash.utils.ByteArray;

internal class ByteArraySegment
{
	public var start:uint;
	public var length:uint;
	public var byteArray:ByteArray;
	public function ByteArraySegment(ba:ByteArray,start:uint,length:uint)
	{
		byteArray=ba;
		this.start=start;
		this.length=length;
	}

		
}


/**
 * This class stores the bytecode necessary to generate a SoundClass SWF.
 * When assembled and loaded, the swf will contain a definition for class SoundClass, that contains the audio.
 * The way SWF bytecode is generated is by writing data in the following order into a ByteArray:
 * 
 * soundClassSwfBytes1
 * UI32: the total size of the SWF in bytes
 * soundClassSwfBytes2
 * UI32: the size of the audio data in bytes+7
 * Byte: 1
 * Byte: 0
 * 4 bits: 3 for uncompressed or 2 for mp3
 * 2 bits: The sample rate. (0=5512.5hZ 1=11025hZ 2=22050hZ 3=44100hZ)
 * 1 bit: The sample depth. (0=8bit, 1=16bit)
 * 1 bit: Channels. (0=mono, 1=stereo)
 * UI32: The number of samples in the audio data (incl seekSamples if mp3)
 * [SI16 seekSamples]
 * audio data
 * soundClassSwfBytes3 
 * 
 * @author spender
 * 
 */
internal final class SoundClassSwfByteCode
{
	internal static const silentMp3Frame:Array=
		[
			0xFF , 0xFA , 0x92 , 0x40 , 0x78 , 0x05 , 0x00 , 0x00 , 0x00 , 0x00 , 0x00,
			0x4B , 0x80 , 0x00 , 0x00 , 0x08 , 0x00 , 0x00 , 0x09 , 0x70 , 0x00 , 0x00,
			0x01 , 0x00 , 0x00 , 0x01 , 0x2E , 0x00 , 0x00 , 0x00 , 0x20 , 0x00 , 0x00,
			0x25 , 0xC0 , 0x00 , 0x00 , 0x04 , 0xB0 , 0x04 , 0xB1 , 0x00 , 0x06 , 0xBA,
			0xA8 , 0x22 , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF,
			0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF , 0xFF
		]
	internal static const soundClassSwfBytes1:Array=
		[ 
			0x46 , 0x57 , 0x53 , 0x09 
		];
	internal static const soundClassSwfBytes2:Array=
		[	
			0x78 , 0x00 , 0x05 , 0x5F , 0x00 , 0x00 , 0x0F , 0xA0 , 
			0x00 , 0x00 , 0x0C , 0x01 , 0x00 , 0x44 , 0x11 , 0x08 , 
			0x00 , 0x00 , 0x00 , 0x43 , 0x02 , 0xFF , 0xFF , 0xFF , 
			0xBF , 0x15 , 0x0B , 0x00 , 0x00 , 0x00 , 0x01 , 0x00 , 
			0x53 , 0x63 , 0x65 , 0x6E , 0x65 , 0x20 , 0x31 , 0x00 , 
			0x00 , 0xBF , 0x14 , 0xC8 , 0x00 , 0x00 , 0x00 , 0x00 , 
			0x00 , 0x00 , 0x00 , 0x00 , 0x10 , 0x00 , 0x2E , 0x00 , 
			0x00 , 0x00 , 0x00 , 0x08 , 0x0A , 0x53 , 0x6F , 0x75 , 
			0x6E , 0x64 , 0x43 , 0x6C , 0x61 , 0x73 , 0x73 , 0x00 , 
			0x0B , 0x66 , 0x6C , 0x61 , 0x73 , 0x68 , 0x2E , 0x6D , 
			0x65 , 0x64 , 0x69 , 0x61 , 0x05 , 0x53 , 0x6F , 0x75 , 
			0x6E , 0x64 , 0x06 , 0x4F , 0x62 , 0x6A , 0x65 , 0x63 , 
			0x74 , 0x0F , 0x45 , 0x76 , 0x65 , 0x6E , 0x74 , 0x44 , 
			0x69 , 0x73 , 0x70 , 0x61 , 0x74 , 0x63 , 0x68 , 0x65 , 
			0x72 , 0x0C , 0x66 , 0x6C , 0x61 , 0x73 , 0x68 , 0x2E , 
			0x65 , 0x76 , 0x65 , 0x6E , 0x74 , 0x73 , 0x06 , 0x05 , 
			0x01 , 0x16 , 0x02 , 0x16 , 0x03 , 0x18 , 0x01 , 0x16 , 
			0x07 , 0x00 , 0x05 , 0x07 , 0x02 , 0x01 , 0x07 , 0x03 , 
			0x04 , 0x07 , 0x02 , 0x05 , 0x07 , 0x05 , 0x06 , 0x03 , 
			0x00 , 0x00 , 0x02 , 0x00 , 0x00 , 0x00 , 0x02 , 0x00 , 
			0x00 , 0x00 , 0x02 , 0x00 , 0x00 , 0x01 , 0x01 , 0x02 , 
			0x08 , 0x04 , 0x00 , 0x01 , 0x00 , 0x00 , 0x00 , 0x01 , 
			0x02 , 0x01 , 0x01 , 0x04 , 0x01 , 0x00 , 0x03 , 0x00 , 
			0x01 , 0x01 , 0x05 , 0x06 , 0x03 , 0xD0 , 0x30 , 0x47 , 
			0x00 , 0x00 , 0x01 , 0x01 , 0x01 , 0x06 , 0x07 , 0x06 , 
			0xD0 , 0x30 , 0xD0 , 0x49 , 0x00 , 0x47 , 0x00 , 0x00 , 
			0x02 , 0x02 , 0x01 , 0x01 , 0x05 , 0x1F , 0xD0 , 0x30 , 
			0x65 , 0x00 , 0x5D , 0x03 , 0x66 , 0x03 , 0x30 , 0x5D , 
			0x04 , 0x66 , 0x04 , 0x30 , 0x5D , 0x02 , 0x66 , 0x02 , 
			0x30 , 0x5D , 0x02 , 0x66 , 0x02 , 0x58 , 0x00 , 0x1D , 
			0x1D , 0x1D , 0x68 , 0x01 , 0x47 , 0x00 , 0x00 , 0xBF , 
			0x03 
		];
	internal static const soundClassSwfBytes3:Array=
		[ 
			0x3F , 0x13 , 0x0F , 0x00 , 0x00 , 0x00 , 0x01 , 0x00 , 
			0x01 , 0x00 , 0x53 , 0x6F , 0x75 , 0x6E , 0x64 , 0x43 , 
			0x6C , 0x61 , 0x73 , 0x73 , 0x00 , 0x44 , 0x0B , 0x0F , 
			0x00 , 0x00 , 0x00 , 0x40 , 0x00 , 0x00 , 0x00 
		];
	
}