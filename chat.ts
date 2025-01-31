import { BehaviorSubject, Observable } from 'npm:rxjs@7.8.1';
import localforage from 'npm:localforage';
import { TextLineStream } from 'https://deno.land/std@0.224.0/streams/mod.ts';

class ChatService {
  private channelId: string;
  private storageKey: string;
  private channelsKey: string;
  private messages: BehaviorSubject<any[]>;
  private cache: any[];

  constructor(channelId: string) {
    this.channelId = channelId;
    this.storageKey = `CHANNEL#${channelId}`;
    this.channelsKey = 'channels';
    this.messages = new BehaviorSubject<any[]>([]);
    this.cache = [];
    this._init();
  }

  private async _init(): Promise<void> {
    const channels: string[] = (await localforage.getItem(this.channelsKey)) || [];
    if (!channels.includes(this.channelId)) {
      await localforage.setItem(this.channelsKey, [...channels, this.channelId]);
    }
    const storedMessages: any[] = (await localforage.getItem(this.storageKey)) || [];
    this.cache = storedMessages.slice(-20);
    this.messages.next([...this.cache]);
  }

  public getMessages(): Observable<any[]> {
    return this.messages.asObservable();
  }

  public async addMessage(content: string, author: string): Promise<any> {
    const newMessage = {
      id: Date.now().toString(),
      content,
      author,
      timestamp: new Date().toISOString(),
    };
    
    const storedMessages: any[] = (await localforage.getItem(this.storageKey)) || [];
    storedMessages.push(newMessage);
    await localforage.setItem(this.storageKey, storedMessages);
    
    this.cache.push(newMessage);
    this.messages.next([...this.cache]);
    return newMessage;
  }

  public async editMessage(id: string, newContent: string): Promise<void> {
    const storedMessages: any[] = (await localforage.getItem(this.storageKey)) || [];
    const message = storedMessages.find((msg) => msg.id === id);
    if (message) {
      message.content = newContent;
      await localforage.setItem(this.storageKey, storedMessages);
    }
    
    const cacheMessage = this.cache.find((msg) => msg.id === id);
    if (cacheMessage) {
      cacheMessage.content = newContent;
      this.messages.next([...this.cache]);
    }
  }

  public async deleteMessage(id: string): Promise<void> {
    let storedMessages: any[] = (await localforage.getItem(this.storageKey)) || [];
    storedMessages = storedMessages.filter((msg) => msg.id !== id);
    await localforage.setItem(this.storageKey, storedMessages);
    
    this.cache = this.cache.filter((msg) => msg.id !== id);
    this.messages.next([...this.cache]);
  }
}

// Example usage
const chatService = new ChatService('general');
chatService.getMessages().subscribe((messages) => {
  console.clear();
  console.log('Chat Messages:');
  messages.forEach(msg => console.log(`[${msg.timestamp}] ${msg.author}: ${msg.content}`));
  console.log('\nType a message and press Enter:');
});

const readInput = async () => {
  for await (const line of Deno.stdin.readable.pipeThrough(new TextDecoderStream()).pipeThrough(new TextLineStream())) {
    if (line.trim()) {
      await chatService.addMessage(line.trim(), 'User');
    }
  }
};

readInput();
