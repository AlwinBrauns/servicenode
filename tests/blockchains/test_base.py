import tempfile
import unittest.mock
import uuid

import pytest
from vision.common.blockchains.base import BlockchainUtilities
from vision.common.blockchains.base import BlockchainUtilitiesError
from vision.common.blockchains.enums import Blockchain
from vision.common.entities import TransactionStatus

from vision.servicenode.blockchains.base import BlockchainClient
from vision.servicenode.blockchains.base import BlockchainClientError
from vision.servicenode.blockchains.base import \
    UnresolvableTransferSubmissionError

_MOCK_CONFIG = {
    'provider': '',
    'fallback_providers': [''],
    'average_block_time': 14,
    'confirmations': 12,
    'chain_id': 1,
    'vsn_token': '0xcd8fa68c471d7703C074EA5e2C56B852795B33c0',
    'private_key': tempfile.mkstemp()[1],
    'private_key_password': 'some_password'
}

_INTERNAL_TRANSACTION_ID = uuid.uuid4()

_DESTINATION_BLOCKCHAIN = Blockchain.SONIC

_TRANSACTION_ID = \
    '0x5792e26d11cdf54155de59de5ddcca3f9d084ce89f4b5d4f9e50ec30c726be70'

_ON_CHAIN_TRANSFER_ID = 10512

_OWN_ADDRESS = '0x7De6Ce2Ce98B446CdD2730d2D49B0e1FEe2Ff85C'

_OWN_VSN_BALANCE = 10**5 * 10**8


@pytest.fixture(scope='module')
@unittest.mock.patch(
    'vision.servicenode.blockchains.base.initialize_blockchain_utilities')
@unittest.mock.patch.object(BlockchainClient, '_get_config',
                            return_value=_MOCK_CONFIG)
@unittest.mock.patch.object(BlockchainClient, 'get_blockchain',
                            return_value=Blockchain(0))
@unittest.mock.patch.object(BlockchainClient, '__abstractmethods__', set())
def blockchain_client(mock_get_blockchain, mock_get_config,
                      mock_initialize_blockchain_utilities, config_dict):
    with unittest.mock.patch('vision.servicenode.blockchains.base.config',
                             config_dict):
        return BlockchainClient()


@unittest.mock.patch(
    'vision.servicenode.blockchains.base.initialize_blockchain_utilities')
@unittest.mock.patch.object(BlockchainClient, '_get_config',
                            return_value=_MOCK_CONFIG)
@unittest.mock.patch.object(BlockchainClient, 'get_blockchain',
                            return_value=Blockchain(0))
@unittest.mock.patch.object(BlockchainClient, '__abstractmethods__', set())
def test_init_correct(mock_get_blockchain, mock_get_config,
                      mock_initialize_blockchain_utilities, config_dict):
    with unittest.mock.patch('vision.servicenode.blockchains.base.config',
                             config_dict):
        BlockchainClient()
    mock_initialize_blockchain_utilities.assert_called_once()


@unittest.mock.patch(
    'vision.servicenode.blockchains.base.initialize_blockchain_utilities',
    side_effect=BlockchainUtilitiesError(''))
@unittest.mock.patch.object(BlockchainClient, '_create_error',
                            return_value=BlockchainClientError(''))
@unittest.mock.patch.object(BlockchainClient, '_get_config',
                            return_value=_MOCK_CONFIG)
@unittest.mock.patch.object(BlockchainClient, 'get_blockchain',
                            return_value=Blockchain(0))
@unittest.mock.patch.object(BlockchainClient, '__abstractmethods__', set())
def test_init_error(mock_get_blockchain, mock_get_config, mock_create_error,
                    mock_initialize_blockchain_utilities, config_dict):
    with pytest.raises(BlockchainClientError) as exception_info:
        with unittest.mock.patch('vision.servicenode.blockchains.base.config',
                                 config_dict):
            BlockchainClient()
    assert isinstance(exception_info.value.__context__,
                      BlockchainUtilitiesError)


@unittest.mock.patch.object(BlockchainClient, 'get_own_address',
                            return_value=_OWN_ADDRESS)
@unittest.mock.patch.object(BlockchainClient, '_get_utilities')
@unittest.mock.patch.object(BlockchainClient, '_get_config',
                            return_value=_MOCK_CONFIG)
def test_read_own_vsn_balance_correct(mock_get_config, mock_get_utilities,
                                      mock_get_own_address, blockchain_client):
    mock_get_utilities().get_balance.return_value = _OWN_VSN_BALANCE
    own_vsn_balance = blockchain_client.read_own_vsn_balance()
    assert own_vsn_balance == _OWN_VSN_BALANCE


@unittest.mock.patch.object(BlockchainClient, 'get_own_address',
                            return_value=_OWN_ADDRESS)
@unittest.mock.patch.object(BlockchainClient, '_get_utilities')
@unittest.mock.patch.object(BlockchainClient, '_get_config',
                            return_value=_MOCK_CONFIG)
@unittest.mock.patch.object(BlockchainClient, 'get_error_class',
                            return_value=BlockchainClientError)
def test_read_own_vsn_balance_error(mock_get_error_class, mock_get_config,
                                    mock_get_utilities, mock_get_own_address,
                                    blockchain_client):
    mock_get_utilities().get_balance.side_effect = BlockchainUtilitiesError('')
    with pytest.raises(BlockchainClientError):
        blockchain_client.read_own_vsn_balance()


@unittest.mock.patch.object(BlockchainClient, '_get_utilities')
def test_get_transfer_submission_status_not_completed(mock_get_utilities,
                                                      blockchain_client):
    mock_get_utilities().get_transaction_submission_status.return_value = \
        BlockchainUtilities.TransactionSubmissionStatusResponse(False)
    status_response = blockchain_client.get_transfer_submission_status(
        _INTERNAL_TRANSACTION_ID, _DESTINATION_BLOCKCHAIN)
    assert not status_response.transaction_submission_completed


@pytest.mark.parametrize(
    'transaction_status',
    [TransactionStatus.CONFIRMED, TransactionStatus.REVERTED])
@unittest.mock.patch.object(BlockchainClient, '_read_on_chain_transfer_id',
                            return_value=_ON_CHAIN_TRANSFER_ID)
@unittest.mock.patch.object(BlockchainClient, '_get_utilities')
def test_get_transfer_submission_status_completed(
        mock_get_utilities, mock_read_on_chain_transfer_id, transaction_status,
        blockchain_client):
    mock_get_utilities().get_transaction_submission_status.return_value = \
        BlockchainUtilities.TransactionSubmissionStatusResponse(
            True, transaction_status, _TRANSACTION_ID)
    status_response = blockchain_client.get_transfer_submission_status(
        _INTERNAL_TRANSACTION_ID, _DESTINATION_BLOCKCHAIN)
    assert status_response.transaction_submission_completed
    assert status_response.transaction_status is transaction_status
    assert status_response.transaction_id == _TRANSACTION_ID
    if transaction_status is TransactionStatus.CONFIRMED:
        assert status_response.on_chain_transfer_id == _ON_CHAIN_TRANSFER_ID


@unittest.mock.patch.object(BlockchainClient, '_get_utilities')
@unittest.mock.patch.object(BlockchainClient, 'get_error_class',
                            return_value=BlockchainClientError)
def test_get_transfer_submission_status_error(mock_get_error_class,
                                              mock_get_utilities,
                                              blockchain_client):
    mock_get_utilities().get_transaction_submission_status.side_effect = \
        BlockchainUtilitiesError('')
    with pytest.raises(UnresolvableTransferSubmissionError):
        blockchain_client.get_transfer_submission_status(
            _INTERNAL_TRANSACTION_ID, _DESTINATION_BLOCKCHAIN)
