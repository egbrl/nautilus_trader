#!/usr/bin/env python3
# -------------------------------------------------------------------------------------------------
# <copyright file="portfolio.pyx" company="Invariance Pte">
#  Copyright (C) 2018-2019 Invariance Pte. All rights reserved.
#  The use of this source code is governed by the license as found in the LICENSE.md file.
#  http://www.invariance.com
# </copyright>
# -------------------------------------------------------------------------------------------------

# cython: language_level=3, boundscheck=False, wraparound=False, nonecheck=False

from typing import List, Dict
from threading import Lock

from inv_trader.core.precondition cimport Precondition
from inv_trader.common.logger cimport Logger, LoggerAdapter
from inv_trader.common.clock cimport LiveClock
from inv_trader.common.guid cimport LiveGuidFactory
from inv_trader.common.execution cimport ExecutionClient
from inv_trader.model.events cimport Event, PositionOpened, PositionModified, PositionClosed
from inv_trader.model.identifiers cimport GUID, OrderId, PositionId
from inv_trader.model.position cimport Position


cdef class Portfolio:
    """
    Represents a trading portfolio of positions.
    """

    def __init__(self,
                 Clock clock=LiveClock(),
                 GuidFactory guid_factory=LiveGuidFactory(),
                 Logger logger=None):
        """
        Initializes a new instance of the Portfolio class.
        """
        if logger is None:
            self._log = LoggerAdapter(self.__class__.__name__)
        else:
            self._log = LoggerAdapter(self.__class__.__name__, logger)

        self._clock = clock
        self._guid_factory = guid_factory
        self._exec_client = None          # Initialized when registered with execution client
        self._position_book = {}          # type: Dict[PositionId, Position]
        self._order_p_index = {}          # type: Dict[OrderId, PositionId]
        self._registered_strategies = []  # type: List[GUID]
        self._positions_active = {}       # type: Dict[GUID, Dict[PositionId, Position]]
        self._positions_closed = {}       # type: Dict[GUID, Dict[PositionId, Position]]

        self._log.info("Initialized.")

    cpdef list registered_strategies(self):
        """
        :return: A list of strategy identifiers registered with the portfolio.
        """
        with Lock():
            return self._registered_strategies.copy()

    cpdef list registered_order_ids(self):
        """
        :return: A list of order identifiers registered with the portfolio.
        """
        with Lock():
            return list(self._order_p_index.keys())

    cpdef list registered_position_ids(self):
        """
        :return: A list of position identifiers registered with the portfolio.
        """
        with Lock():
            return list(self._order_p_index.values())

    cpdef bint position_exists(self, PositionId position_id):
        """
        Return a value indicating whether a position with the given identifier exists.
        
        :param position_id: The position identifier.
        :return: True if the position exists, else False.
        """
        with Lock():
            return position_id in self._position_book

    cpdef Position get_position(self, PositionId position_id):
        """
        Return the position associated with the given identifier.
        
        :param position_id: The position id.
        :return: The position or None if not found.
        :raises ValueError: If the position is not found.
        """
        with Lock():
            Precondition.is_in(position_id, self._position_book, 'position_id', 'position_book')

            return self._position_book[position_id]

    cpdef dict get_positions_all(self):
        """
         Return a dictionary of all positions held by the portfolio.
        
        :return: Dict[PositionId, Position].
        """
        with Lock():
            return self._position_book.copy()

    cpdef dict get_positions_active_all(self):
        """
        Return a dictionary of all active positions held by the portfolio.
        
        :return: Dict[PositionId, Position].
        """
        with Lock():
            return self._positions_active.copy()

    cpdef dict get_positions_closed_all(self):
        """
        Return a dictionary of all closed positions held by the portfolio.
        
        :return: Dict[PositionId, Position].
        """
        with Lock():
            return self._positions_closed.copy()

    cpdef dict get_positions(self, GUID strategy_id):
        """
        Return a list of all positions associated with the strategy id.
        
        :param strategy_id: The strategy identifier associated with the positions.
        :return: Dict[PositionId, Position].
        """
        cpdef dict positions

        with Lock():
            Precondition.is_in(strategy_id, self._positions_active, 'strategy_id', 'positions_active')
            Precondition.is_in(strategy_id, self._positions_closed, 'strategy_id', 'positions_closed')

            positions = {**self._positions_active[strategy_id], **self._positions_closed[strategy_id]}
            return positions  # type: Dict[PositionId, Position]

    cpdef dict get_positions_active(self, GUID strategy_id):
        """
        Return a list of all active positions associated with the strategy id.
        
        :param strategy_id: The strategy identifier associated with the positions.
        :return: Dict[PositionId, Position].
        """
        with Lock():
            Precondition.is_in(strategy_id, self._positions_active, 'strategy_id', 'positions_active')

            return self._positions_active[strategy_id].copy()

    cpdef dict get_positions_closed(self, GUID strategy_id):
        """
        Return a list of all active positions associated with the strategy id.
        
        :param strategy_id: The strategy identifier associated with the positions.
        :return: Dict[PositionId, Position].
        """
        with Lock():
            Precondition.is_in(strategy_id, self._positions_closed, 'strategy_id', 'positions_closed')

            return self._positions_closed[strategy_id].copy()

    cpdef bint is_strategy_flat(self, GUID strategy_id):
        """
        Return a value indicating whether the strategy is flat (all associated positions FLAT).
        
        :param strategy_id: The strategy identifier.
        :return: True if the strategy is flat, else False.
        """
        with Lock():
            return len(self._positions_active[strategy_id]) == 0

    cpdef bint is_flat(self):
        """
        Return a value indicating whether the entire portfolio is flat.
        
        :return: True if the portfolio is flat, else False.
        """
        with Lock():
            for position in self._position_book.values():
                if not position.is_exited:
                    return False
            return True

    cpdef void register_execution_client(self, ExecutionClient client):
        """
        Register the given execution client with the portfolio to receive position events.
        
        :param client: The client to register
        """
        Precondition.not_none(client, 'client')

        self._exec_client = client
        self._log.info("Registered execution client.")

    cpdef void register_strategy(self, GUID strategy_id):
        """
        Register the given strategy identifier with the portfolio.
        
        :param strategy_id: The strategy identifier to register.
        """
        Precondition.true(strategy_id not in self._registered_strategies, 'strategy_id not in self._registered_strategies')
        Precondition.not_in(strategy_id, self._positions_active, 'strategy_id', 'active_positions')
        Precondition.not_in(strategy_id, self._positions_closed, 'strategy_id', 'closed_positions')

        self._registered_strategies.append(strategy_id)
        self._positions_active[strategy_id] = {}  # type: Dict[PositionId, Position]
        self._positions_closed[strategy_id] = {}  # type: Dict[PositionId, Position]
        self._log.info(f"Registered strategy with id {strategy_id}.")

    cpdef void register_order(self, OrderId order_id, PositionId position_id):
        """
        Register the given order identifier with the given position identifier.
        
        :param order_id: The order identifier to register.
        :param position_id: The position identifier to register.
        """
        # Lock should not be needed as the execution client is the only caller.

        Precondition.not_in(order_id, self._order_p_index, 'order_id', 'order_position_index')

        self._order_p_index[order_id] = position_id

    cpdef void handle_event(self, Event event, GUID strategy_id):
        """
        Handle the given event associated with the given strategy identifier.
        
        :param event: The event to handle.
        :param strategy_id: The strategy identifier.
        """
        # Lock should not be needed as the execution client is the only caller.

        Precondition.is_in(event.order_id, self._order_p_index, 'event.order_id', 'order_position_index')

        cdef PositionId position_id = self._order_p_index[event.order_id]
        cdef Position position

        # Position does not exist yet
        if position_id not in self._position_book:
            position = Position(
                event.symbol,
                position_id,
                event.execution_time)
            position.apply(event)

            # Add position to position book
            self._position_book[position_id] = position

            # Add position to active positions
            assert(position_id not in self._positions_active[strategy_id])
            self._positions_active[strategy_id][position_id] = position
            self._log.debug(f"{position} added to active positions.")
            self._position_opened(position)

        # Position exists
        else:
            position = self._position_book[position_id]
            position.apply(event)

            if position.is_exited:
                # Move to closed positions
                if position_id in self._positions_active[strategy_id]:
                    self._positions_closed[strategy_id][position_id] = position
                    del self._positions_active[strategy_id][position_id]
                    self._log.debug(f"Moved {position} to closed positions.")
                    self._position_closed(position)
            else:
                # Check for overfill
                if position_id in self._positions_closed[strategy_id]:
                    self._positions_active[strategy_id][position_id] = position
                    del self._positions_closed[strategy_id][position_id]
                    self._log.debug(f"Moved {position} BACK to active positions due overfill.")
                    self._position_opened(position)
                self._position_modified(position)

    cdef void _position_opened(self, Position position):
        self._log.info(f"Opened {position}")

        self._exec_client.handle_event(PositionOpened(
            position,
            self._guid_factory.generate(),
            self._clock.time_now()))

    cdef void _position_modified(self, Position position):
        self._log.info(f"Modified {position}")

        self._exec_client.handle_event(PositionModified(
            position,
            self._guid_factory.generate(),
            self._clock.time_now()))

    cdef void _position_closed(self, Position position):
        self._log.info(f"Closed {position}")

        self._exec_client.handle_event(PositionClosed(
            position,
            self._guid_factory.generate(),
            self._clock.time_now()))
