module Client where
{-# LANGUAGE OverloadedStrings #-}


import Network.Socket hiding (send, sendTo, recv, recvFrom)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString as BS
import Debug.Trace
import Network.Socket.ByteString as NB
import Data.Int (Int64)
import Data.Maybe
import System.IO (hPutStrLn, stderr)
import Payloads.Payload
import qualified Data.Binary as DB
import Data.Version(showVersion)
import Types

import qualified Payloads.BasicPayload as BasicPayload
import qualified Payloads.ConnectionPayload as ConnectionPayload
import qualified Payloads.ChannelPayload as ChannelPayload
import qualified Payloads.ExchangePayload as ExchangePayload
import qualified Payloads.HeaderPayload as HeaderPayload
import qualified Payloads.QueuePayload as QueuePayload
import qualified Payloads.ContentPayload as ContentPayload
import qualified Data.Map.Strict as Map

import qualified Data.Text.Encoding as E
import qualified Data.Text as T
import Frame

import Data.Binary.Get
import Data.Word
import qualified Data.ByteString.Lazy as BL
import Control.Monad.Trans.Except
import Data.Bifunctor
import Control.Monad.Trans.Class
import Control.Monad
import Control.Concurrent

type MM = (MVar (Map.Map Int (Chan Frame)))

data ServerAddress = ServerAddress {address :: String, port :: String}
data Connection = ConnectionHandler (MVar Int) (Chan Frame) (MM)
data Channel = ChannelHandler (Chan Frame) (Chan Frame)
data Queue = QueueHandler

getFrameSize = do
    _ <- getWord8
    _ <- DB.get :: (DB.Get Word16)
    a <- DB.get :: (DB.Get Word32)
    return a

getSize :: BL.ByteString -> Integer
getSize bs = fromIntegral $ (runGet getFrameSize) bs

getBytess :: Socket -> IO BS.ByteString
getBytess sock = do
    head <- NB.recv sock 7
    let size = getSize $ BL.fromStrict head
    tail <- NB.recv sock (fromInteger $ size + 1)
    return $ BS.append head tail

third (a, b, c) = c

getFrame :: Socket -> IO (Either String Frame)
getFrame sock = do
    bytes <- getBytess sock
    let x = decode $ BL.fromStrict bytes
    return $ bimap third third x

openTcpConnection :: ServerAddress -> IO Socket
openTcpConnection (ServerAddress address port) = do
    addrInfo <- getAddrInfo Nothing (Just address) (Just port)
    let serverAddr = head addrInfo
    sock <- socket (addrFamily serverAddr) Stream defaultProtocol
    connect sock (addrAddress serverAddr)
    NB.send sock $ BS8.append (BS8.pack "AMQP") (BS.pack [0, 0, 9, 1])
    return sock


decode = runGetOrFail (DB.get :: Get Frame)

q :: Socket -> Chan Frame -> IO ()
q socket chan = forever(do
    frame <- readChan chan
    NB.send socket (BL.toStrict $ DB.encode $ frame))

ii :: Socket -> MM -> IO ()
ii socket mapa = forever(do
    bytes <- NB.recv socket 8192
    let z=  decode $ BL.fromStrict bytes
    let (Right oi) = z
    let (_, _, frame) = oi
    m <- readMVar mapa
    let chanNumber = channel frame
    let ch = m Map.! (fromInteger (toInteger chanNumber))
    writeChan ch frame)
    

openConnection' :: ServerAddress -> Chan Frame -> MM -> IO ()
openConnection' address ch mapa = do
    sock <- openTcpConnection address
    frame <- getFrame sock
    putStrLn $ show frame
    NB.send sock startOk
    bytes2 <- NB.recv sock 8192
    putStrLn (show $ decode $ BL.fromStrict bytes2)
    NB.send sock tuneOk
    NB.send sock open
    bytes4 <- NB.recv sock 8192
    putStrLn (show $ decode $ BL.fromStrict bytes4)
    forkIO (q sock ch)
    ii sock mapa

sendMsg' :: Chan Frame -> Frame -> IO ()
sendMsg' chan = writeChan chan

sendMsg :: Connection -> Frame -> IO ()
sendMsg (ConnectionHandler _ chan _) = sendMsg' chan

sendMsg'' :: Channel -> Frame -> IO ()
sendMsg'' (ChannelHandler out inChan) = sendMsg' out

openConnection :: ServerAddress -> IO Connection
openConnection address = do
    channels <- newMVar 1
    channel <- newChan
    channelMap <- newMVar Map.empty
    _ <- forkIO (openConnection' address channel channelMap)
    return $ ConnectionHandler channels channel channelMap


open = BL.toStrict $ DB.encode $ getConnectionFrame $ ConnectionPayload.Open (ss "/") 
tuneOk = BL.toStrict $ DB.encode $ getConnectionFrame $ ConnectionPayload.TuneOk 0 131072 60

startOk = BL.toStrict $ DB.encode $ getConnectionFrame $ ConnectionPayload.StartOk (FieldTable []) (ss "PLAIN") (LongString plain) (ss "en_US")

ss = ShortString . T.pack

plain :: BS.ByteString
plain = E.encodeUtf8 $ (T.cons nul (T.pack "guest")) `T.append` (T.cons nul (T.pack "guest"))
  where
    nul = '\0'

modifyFun :: Int -> IO (Int, Int)    
modifyFun val = return ((val + 1), val)

takeChannelNumber :: Connection -> IO Int
takeChannelNumber (ConnectionHandler mvar _ _) = modifyMVar mvar modifyFun 

addChannelChan :: Connection -> Int -> IO (Chan Frame)
addChannelChan (ConnectionHandler _ _ mapa) n = do
    newChan <- newChan :: (IO (Chan Frame))
    _ <- modifyMVar_ mapa (\m -> return (Map.insert n newChan m))
    return newChan

receiveMessage :: Int -> Connection -> IO Frame
receiveMessage chn (ConnectionHandler _ _ mapa) = (do
    m <- readMVar mapa
    return $ m Map.! chn) >>= receiveMessage'

receiveMessage' :: Chan Frame -> IO Frame
receiveMessage' chan = readChan chan

receiveMessage'' :: Channel -> IO Frame
receiveMessage'' (ChannelHandler out inChan) = receiveMessage' inChan

openChannel :: Connection -> IO Channel
openChannel connection = do
    chanNum <- takeChannelNumber connection
    inChan <- addChannelChan connection chanNum
    sendMsg connection (openCh (fromIntegral chanNum))
    f <- receiveMessage chanNum connection
    let ConnectionHandler _ out _ = connection 
    return $ ChannelHandler out inChan

openCh chanNum = getChannelFrame (ChannelPayload.Open) chanNum

declareExchange :: Channel -> String -> IO ()
declareExchange (ChannelHandler out inChan) name = do 
    sendMsg' out (de name)
    frame <- receiveMessage' inChan
    putStrLn (show frame)
    return ()

de name = getExchangeFrame $ ExchangePayload.Declare (ExchangeName $ ss name) (ss "direct") False True False (FieldTable [])

declareQueue :: Channel -> String -> IO Queue 
declareQueue (ChannelHandler out inChan) name = do
    sendMsg' out (dq name)
    frame <- receiveMessage' inChan
    putStrLn (show frame)
    return QueueHandler

dq name = getQueueFrame $ QueuePayload.Declare (ss name) False False False False False (FieldTable [])

bindQueue :: Channel -> String -> String -> IO ()
bindQueue channel exName qName = do
    sendMsg'' channel (bq exName qName)
    frame <- receiveMessage'' channel
    putStrLn (show frame)

bq exName qName = getQueueFrame $ QueuePayload.Bind (ss qName) (ExchangeName $ ss exName) (ss "kkk") False (FieldTable []) 

publish :: Connection -> String -> String -> BS.ByteString -> IO ()
publish connection exName routingKey str = do
    _ <- sendMsg connection (p exName routingKey) 
    -- bytes <- NB.recv sock 8192
    -- putStrLn (show $ decode $ BL.fromStrict bytes)

    _ <- sendMsg connection (hp str)

    _ <- sendMsg connection  (pp str)

    return ()

p exName routingKey = getBasicFrame $ BasicPayload.Publish (ExchangeName (ss exName)) (ss routingKey) False False

hp str = getHeaderFrame $ HeaderPayload.HP ((fromIntegral $ BL.length (BL.fromStrict str) :: LongLong))
pp str = getContentFrame $ ContentPayload.CP $ BL.fromStrict str





lkj :: Connection -> IO Frame
lkj connection = receiveMessage 1 connection

    
consume :: Connection -> String -> IO Message
consume connection qName = do 
    let h = (getBasicFrame $ BasicPayload.Consume (ss qName) (ss "abc") False False False False (FieldTable []))
    _ <- sendMsg connection h
    fr <- lkj connection
    frame <- lkj connection
    putStrLn $ show frame
    let ConnectionFrame _ (BasicPayload (BasicPayload.Deliver a b c d)) = frame
    HeaderFrame _ _ <- lkj connection
    ContentFrame _ (ContentPayload.CP(content)) <- lkj connection
    return $ Message b content    

data Message = Message DeliveryTag BL.ByteString deriving Show

ack :: Connection -> DeliveryTag -> IO ()
ack connection tag = do
    _ <- sendMsg connection $ getBasicFrame $ BasicPayload.Ack tag False 
    return ()