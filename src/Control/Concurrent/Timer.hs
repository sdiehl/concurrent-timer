{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Control.Concurrent.Timer (
  Timer,
  newTimer,
  newTimerRange,

  startTimer,
  resetTimer,
  waitTimer,
  runTimer,
  runTimer'
) where

import Protolude hiding (async)

import Control.Concurrent.Async (async, uninterruptibleCancel)
import Control.Concurrent.STM
  ( TMVar, newTMVar, newEmptyTMVar, readTMVar, tryPutTMVar, tryTakeTMVar
  , TVar, newTVar, readTVar, writeTVar
  )
import Numeric.Natural (Natural)
import System.Random (StdGen, mkStdGen, randomR, randomRIO)

data Timer = Timer
  { timerAsync :: TMVar (Async ())
    -- ^ The async computation of the timer
  , timerLock :: TMVar ()
    -- ^ When the TMVar is empty, the timer is being used
  , timerGen :: TVar StdGen
  , timerRange :: (Natural, Natural)
  }

-- | Create a new timer with the supplied timeout
newTimer :: MonadIO m => Natural -> m Timer
newTimer timeout = flip newTimer' timeout =<< randomInt

-- | Create a new timer with a random seed and the supplied timeout
newTimer' :: MonadIO m => Int -> Natural -> m Timer
newTimer' seed timeout = newTimerRange' seed (timeout, timeout)

-- | Create a new timer with the supplied range from which the the timer will
-- choose a random timer length at each start or reset.
newTimerRange :: MonadIO m => (Natural, Natural) -> m Timer
newTimerRange timeoutRange = flip newTimerRange' timeoutRange =<< randomInt

-- | Create a new timer with a random seed and the supplied range from which the
-- the timer will choose a random timer length at each start or reset.
newTimerRange' :: MonadIO m => Int -> (Natural, Natural) -> m Timer
newTimerRange' seed timeoutRange = do
  (timerAsync, timerLock, timerGen) <-
    liftedAtomically $ (,,) <$>
      newEmptyTMVar <*> newTMVar () <*> newTVar (mkStdGen seed)
  pure $ Timer timerAsync timerLock timerGen timeoutRange

--------------------------------------------------------------------------------

data TimerStartFailed = TimerStartFailed

-- | Start the timer. If the timer is already running, the timer is not started.
-- Returns True if the timer was succesfully started.
startTimer :: MonadIO m => Timer -> m (Either TimerStartFailed ())
startTimer timer = do
  mlock <- liftedAtomically $ tryTakeTMVar (timerLock timer)
  case mlock of
    Nothing -> pure (Left TimerStartFailed)
    Just () -> resetTimer timer >> pure (Right ())

-- | Resets the timer. If 'newTimer' was used to create the timer, the timer
-- starts counting down from the timeout provided. If 'newTimerRange' was used
-- to create the timer, a new random timeout in the range of timeouts provided
-- is chosen.
resetTimer :: MonadIO m => Timer -> m ()
resetTimer timer = do

  let liftedAsync = liftIO . async

  -- Check if a timer is already running. If it is, asynchronously kill the
  -- thread.
  mta <- liftedAtomically $ tryTakeTMVar (timerAsync timer)
  case mta of
    Nothing -> pure ()
    Just ta -> void $ liftedAsync (uninterruptibleCancel ta)

  -- Fork a new async computation that waits the specified (random) amount of
  -- time, performs the timer action, and then puts the lock back signaling the
  -- timer finishing.
  ta <- liftIO $ async $ do
    threadDelay =<< randomDelay timer
    success <- liftedAtomically $ tryPutTMVar (timerLock timer) ()
    when (not success) $
      panic "[Failed Invariant]: Putting the timer lock back should succeed"

  -- Check that putting the new async succeeded. If it did not, there is a race
  -- condition and the newly created async should be canceled. Warning: This may
  -- not work for _very_ short timers.
  success <- liftedAtomically $ tryPutTMVar (timerAsync timer) ta
  when (not success) $
    void $ liftedAsync (uninterruptibleCancel ta)

-- | Wait for a timer to complete
waitTimer :: MonadIO m => Timer -> m ()
waitTimer timer = liftedAtomically $ readTMVar (timerLock timer)

-- | Start a timer and wait for it to finish. If a timer is currently running,
-- this function resets that timer and then waits for it to finish.
runTimer :: MonadIO m => Timer -> m ()
runTimer timer = resetTimer timer >> waitTimer timer

-- | Start a timer and wait for it to finish. This function will fail if the timer
-- is already running.
runTimer' :: MonadIO m => Timer -> m (Either TimerStartFailed ())
runTimer' timer = do
  res <- startTimer timer
  case res of
    Left err -> pure (Left err)
    Right () -> Right <$> waitTimer timer

--------------------------------------------------------------------------------

randomInt :: MonadIO m => m Int
randomInt = liftIO $ randomRIO (minBound, maxBound)

randomDelay :: MonadIO m => Timer -> m Int
randomDelay timer = liftedAtomically $ do
  g <- readTVar (timerGen timer)
  let (tmin, tmax) = timerRange timer
      (n, g') = randomR (toInteger tmin, toInteger tmax) g
  writeTVar (timerGen timer) g'
  pure (fromIntegral n)

liftedAtomically :: MonadIO m => STM a -> m a
liftedAtomically = liftIO . atomically
