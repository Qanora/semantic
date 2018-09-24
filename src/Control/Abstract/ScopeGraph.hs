{-# LANGUAGE GADTs, KindSignatures, LambdaCase, RankNTypes, ScopedTypeVariables, TypeOperators #-}
module Control.Abstract.ScopeGraph
  ( runScopeEnv
  , ScopeEnv
  , lookup
  , declare
  , reference
  , newScope
  , Declaration(..)
  , name
  , Reference(..)
  , EdgeLabel(..)
  , currentScope
  , withScope
  , associatedScope
  , putDeclarationScope
  ) where

import           Control.Abstract.Evaluator hiding (Local)
import           Control.Abstract.Heap
import           Data.Abstract.Module
import           Data.Abstract.BaseError
import           Data.Abstract.Name hiding (name)
import           Data.Abstract.ScopeGraph (Declaration (..), EdgeLabel, Reference, ScopeGraph)
import qualified Data.Abstract.ScopeGraph as ScopeGraph
import           Data.Span
import           Prelude hiding (lookup)
import           Prologue

data ScopeEnv address (m :: * -> *) a where
    Lookup :: Reference -> ScopeEnv address m (Maybe address)
    Declare :: Declaration -> Span -> Maybe address -> ScopeEnv address m (Address address)
    PutDeclarationScope :: Declaration -> address -> ScopeEnv address m ()
    Reference :: Reference -> Declaration -> ScopeEnv address m ()
    NewScope :: Map EdgeLabel [address] -> ScopeEnv address m address
    CurrentScope :: ScopeEnv address m (Maybe address)
    Local :: address -> m a -> ScopeEnv address m a
    AssociatedScope :: Declaration -> ScopeEnv address m (Maybe address)

lookup :: forall address value effects. Member (ScopeEnv address) effects => Reference -> Evaluator address value effects (Maybe address)
lookup = send . Lookup @address

declare :: forall address value effects. Member (ScopeEnv address) effects => Declaration -> Span -> Maybe address -> Evaluator address value effects (Address address)
declare = ((send .) .) . Declare @address

putDeclarationScope :: forall address value effects. Member (ScopeEnv address) effects => Declaration -> address -> Evaluator address value effects ()
putDeclarationScope = (send .) . PutDeclarationScope @address

reference :: forall address value effects. Member (ScopeEnv address) effects => Reference -> Declaration -> Evaluator address value effects ()
reference = (send .) . Reference @address

newScope :: forall address value effects. (Member (ScopeEnv address) effects) => Map EdgeLabel [address]  -> Evaluator address value effects address
newScope = send . NewScope @address

currentScope :: forall address value effects. Member (ScopeEnv address) effects => Evaluator address value effects (Maybe address)
currentScope = send CurrentScope

associatedScope :: forall address value effects. Member (ScopeEnv address) effects => Declaration -> Evaluator address value effects (Maybe address)
associatedScope = send . AssociatedScope

withScope :: forall address value effects m a. (Effectful (m address value), Member (ScopeEnv address) effects) => address -> m address value effects a -> m address value effects a
withScope scope action = send (Local scope (lowerEff action))

instance PureEffect (ScopeEnv address)
instance Effect (ScopeEnv address) where
  handleState c dist (Request (Lookup ref) k)         = Request (Lookup ref) (dist . (<$ c) . k)
  handleState c dist (Request (Declare decl span assocScope) k) = Request (Declare decl span assocScope) (dist . (<$ c) . k)
  handleState c dist (Request (PutDeclarationScope decl assocScope) k) = Request (PutDeclarationScope decl assocScope) (dist . (<$ c) . k)
  handleState c dist (Request (Reference ref decl) k) = Request (Reference ref decl) (dist . (<$ c) . k)
  handleState c dist (Request (NewScope edges) k)       = Request (NewScope edges) (dist . (<$ c) . k)
  handleState c dist (Request CurrentScope k)         = Request CurrentScope (dist . (<$ c) . k)
  handleState c dist (Request (AssociatedScope decl) k)         = Request (AssociatedScope decl) (dist . (<$ c) . k)
  handleState c dist (Request (Local scope action) k) = Request (Local scope (dist (action <$ c))) (dist . fmap k)


runScopeEnv :: (Ord address, Effects effects, Member Fresh effects, Member (Allocator address) effects, Member (Resumable (BaseError (ScopeError address))) effects, Member (Reader ModuleInfo) effects, Member (Reader Span) effects)
            => Evaluator address value (ScopeEnv address ': effects) a
            -> Evaluator address value effects (ScopeGraph address, a)
runScopeEnv evaluator = runState lowerBound (reinterpret handleScopeEnv evaluator)

handleScopeEnv :: forall address value effects a. (Ord address
                , Member Fresh effects
                , Member (Allocator address) effects
                , Member (Resumable (BaseError (ScopeError address))) effects
                , Member (Reader ModuleInfo) effects
                , Member (Reader Span) effects
                , Effects effects)
               => ScopeEnv address (Eff (ScopeEnv address ': effects)) a
               -> Evaluator address value (State (ScopeGraph address) ': effects) a
handleScopeEnv = \case
    Lookup ref -> ScopeGraph.scopeOfRef ref <$> get
    Declare decl span scope -> do
        graph <- get
        let (graph', position) = ScopeGraph.declare decl span scope graph
        put graph'
        currentScope <- ScopeGraph.currentScope <$> get
        case (currentScope, position) of
            (Just scope, Just position) -> pure (Address scope position)
            _ -> throwScopeError (ScopeError decl span)
    PutDeclarationScope decl scope -> modify @(ScopeGraph address) (ScopeGraph.insertDeclarationScope decl scope)
    Reference ref decl -> modify @(ScopeGraph address) (ScopeGraph.reference ref decl)
    NewScope edges -> do
        -- Take the edges and construct a new scope, update the current scope to the new scope
        name <- gensym
        address <- alloc name
        address <$ modify @(ScopeGraph address) (ScopeGraph.newScope address edges)
    CurrentScope -> ScopeGraph.currentScope <$> get
    AssociatedScope decl -> ScopeGraph.associatedScope decl <$> get
    Local scope action -> do
        prevScope <- ScopeGraph.currentScope <$> get
        modify @(ScopeGraph address) (\g -> g { ScopeGraph.currentScope = Just scope })
        value <- reinterpret handleScopeEnv (raiseEff action)
        modify @(ScopeGraph address) (\g -> g { ScopeGraph.currentScope = prevScope })
        pure value

throwScopeError :: ( Member (Resumable (BaseError (ScopeError address))) effects
                   , Member (Reader ModuleInfo) effects
                   , Member (Reader Span) effects
                   )
            => ScopeError address resume
            -> Evaluator address value effects resume
throwScopeError = throwBaseError

data ScopeError address return where
  ScopeError :: Declaration -> Span -> ScopeError address (Address address)

deriving instance Eq (ScopeError address return)
deriving instance Show (ScopeError address return)
instance Show address => Show1 (ScopeError address) where liftShowsPrec _ _ = showsPrec
instance Eq address => Eq1 (ScopeError address) where liftEq _ (ScopeError m1 n1) (ScopeError m2 n2) = m1 == m2 && n1 == n2
