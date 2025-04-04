"""Module for creating and initializing a Celery instance.

"""
import logging
import os
import pathlib
import sys

import amqp  # type: ignore
import celery  # type: ignore
import certifi  # type: ignore
from vision.common.logging import LogFile
from vision.common.logging import LogFormat
from vision.common.logging import initialize_logger

from vision.servicenode.application import initialize_application
from vision.servicenode.blockchains.middlewares import NodeHealthMiddleware
from vision.servicenode.configuration import config
from vision.servicenode.configuration import load_config
from vision.servicenode.database import get_engine
from vision.servicenode.plugins import initialize_plugins

_TRANSFERS_QUEUE_NAME = 'transfers'
_BIDS_QUEUE_NAME = 'bids'
_TRANSACTIONS_QUEUE_NAME = 'transactions'

_logger = logging.getLogger(__name__)
"""Logger for this module."""


def celery_after_return_handler(self, status, retval, task_id, args, kwargs,
                                einfo):
    """Handler for the after_return signal.

    Parameters
    ----------
    self : celery.Task
        Task instance.
    status : str
        Current task state.
    retval : Any
        Task return value/exception.
    task_id : str
        Unique id of the task.
    args : Tuple
        Original arguments for the task that returned.
    kwargs : Dict
        Original keyword arguments for the task that returned.
    einfo : ExceptionInfo
        ExceptionInfo instance, containing the traceback (if any).

    The return value of this handler is ignored.
    """
    NodeHealthMiddleware.flush_health_data()  # pragma: no cover


def is_main_module() -> bool:
    """Determine if the current process is a Celery worker process.

    Returns
    -------
    bool
        True if the current process is a Celery worker process.

    """
    potential_celery_markers = [
        'celery', 'worker', 'beat', 'flower', 'report', 'ping'
    ]
    return (__name__ == '__main__'
            or any(marker in sys.argv for marker in potential_celery_markers))


def verify_celery_url_has_ssl() -> bool:
    """Determine if the Celery broker URL has SSL enabled.

    Returns
    -------
    bool
        True if the Celery broker URL has SSL enabled.
    """
    if "CELERY_BROKER" in os.environ:
        url_to_check = os.environ["CELERY_BROKER"]
    else:
        url_to_check = config['celery']['broker']
    return url_to_check.startswith('amqps')


if is_main_module():  # pragma: no cover
    _logger.info('Initializing the Celery application...')
    initialize_application(False)
else:
    _logger.info('Celery application initialization skipped...')
    load_config(reload=False)

ca_certs = {'ca_certs': certifi.where()} if verify_celery_url_has_ssl() else {}

celery_app = celery.Celery(
    'vision.servicenode', broker=config['celery']['broker'],
    backend=config['celery']['backend'], include=[
        'vision.common.blockchains.tasks',
        'vision.servicenode.business.transfers',
        'vision.servicenode.business.plugins'
    ], broker_use_ssl=ca_certs)
"""Celery application instance."""

# Additional Celery configuration
celery_app.conf.update(
    result_expires=None,
    task_default_exchange='vision.servicenode',
    task_default_queue='transfers',
    task_routes={
        'vision.servicenode.business.plugins.execute_bid_plugin': {
            'queue': _BIDS_QUEUE_NAME
        },
        'vision.servicenode.business.transfers.*': {
            'queue': _TRANSFERS_QUEUE_NAME
        },
        'vision.common.blockchains.tasks._transaction_resubmission_task': {
            'queue': _TRANSFERS_QUEUE_NAME
        },
        'vision.servicenode.business.tasks.'
        '_dependent_transaction_submission_task': {
            'queue': _TRANSACTIONS_QUEUE_NAME
        }  # yapf: disable
    },
    task_annotations={'*': {
        'after_return': celery_after_return_handler
    }},
    task_track_started=True,
    worker_enable_remote_control=False,
    # Make sure the broker crashes if it can't connect on startup
    broker_connection_retry=10,
    broker_channel_error_retry=True,
    broker_connection_retry_on_startup=False)

if is_main_module():  # pragma: no cover
    # purge the bids queue at startup
    with celery_app.connection_for_write() as connection:
        try:
            connection.default_channel.queue_purge(_BIDS_QUEUE_NAME)
        except amqp.exceptions.NotFound as error:
            _logger.warning(str(error))
    initialize_plugins(start_worker=True)


@celery.signals.after_setup_task_logger.connect  # Celery task logger
@celery.signals.after_setup_logger.connect  # Celery logger
def setup_logger(logger: logging.Logger, *args, **kwargs):
    """Sent after the setup of every single task and Celery logger.
    Used to augment logging configuration.

    Parameters
    ----------
    logger: logging.Logger
        Logger object to be augmented.

    """
    log_format = LogFormat.from_name(config['celery']['log']['format'])
    standard_output = config['celery']['log']['console']['enabled']
    if not config['celery']['log']['file']['enabled']:
        log_file = None
    else:
        file_path = pathlib.Path(config['celery']['log']['file']['name'])
        max_bytes = config['celery']['log']['file']['max_bytes']
        backup_count = config['celery']['log']['file']['backup_count']
        log_file = LogFile(file_path, max_bytes, backup_count)
    debug = config['application']['debug']
    try:
        initialize_logger(logger, log_format, standard_output, log_file, debug)
    except Exception:
        logger.critical('unable to initialize logging', exc_info=True)
        sys.exit(1)


# Source: https://stackoverflow.com/questions/43944787/sqlalchemy-celery-with-scoped-session-error/54751019#54751019 # noqa
@celery.signals.worker_process_init.connect
def prep_db_pool(**kwargs):
    """
    When Celery forks the parent process, it includes the db engine & connection
    pool. However, db connections should not be shared across processes. Thus,
    we instruct the engine to dispose of all existing connections, prompting the
    opening of new ones in child processes as needed.
    More info:
    https://docs.sqlalchemy.org/en/latest/core/pooling.html#using-connection-pools-with-multiprocessing
    """ # noqa
    get_engine().dispose()  # pragma: no cover
