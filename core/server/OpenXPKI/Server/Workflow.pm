
package OpenXPKI::Server::Workflow;

use base qw( Workflow );

use strict;
use warnings;
use utf8;
use English;
use Carp qw(croak carp);
use Scalar::Util 'blessed';
use Workflow::Exception qw( workflow_error );

use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Exception;
use OpenXPKI::Debug;
use OpenXPKI::Serialization::Simple;
use OpenXPKI::DateTime;

use Data::Dumper;

my @FIELDS = qw( proc_state count_try wakeup_at reap_at session_info);
__PACKAGE__->mk_accessors(@FIELDS);


my $default_reap_at_interval = '+0000000005';

my %known_proc_states = (
    
    #"action" defines, what should happen (=which hook-method sholuld be called), when execute_action is called on  this proc_state
    # example: if proc_state eq 'pause', '_wake_up' is called (IN current Activity-Object!)
    # 'none' means: no specail action needed (=no hook is called), process can go on
    #
    # '_runtime_exception' means: its not allowed (and should not be possible) to (re-)enter a 
    # workflow with this proc_state (e.g 'finished' or 'wakeup'). 
    #
    # see "_handle_proc_state" for details            
    
    init        => {desc => 'set in constructor, no action executed yet',
                    action=>'none'},
    wakeup      => {desc =>'wakeup after pause',
                    action=>'_runtime_exception'},
    resume      => {desc =>'resume after exception',
                    action=>'_runtime_exception'},           
    running     => {desc =>'action executes',
                    action=>'none'},
    manual      => {desc =>'action stops regulary',
                    action=>'none'},
    finished    => {desc =>'action finished with success',
                    action=>'none'},#perfectly handled from WF-State-Engine
    pause       => {desc =>'action paused',
                    action=>'_wake_up'},
    exception   => {desc =>'an exception has been thrown',
                    action=>'_resume'},
    retry_exceeded   => {desc =>'count of retries has been exceeded',
                    action=>'_resume'},

);


sub new {
    my ( $class, $BaseWorkflow, $Factory, $wfData ) = @_;
    my $self = bless {}, $class;

    $wfData = {} unless ref $wfData;

    #take over all properties from (original) base workflow
    while ( my ( $key, $val ) = each %{$BaseWorkflow} ) {
        $self->{$key} = $val;
    }
    ##! 1: 'Workflow::new: '. $self->id
    ##! 128: 'DB-data: '. Dumper($wfData)

    #we need the Factory for commiting the curent proc-state:
    $self->{_FACTORY} = $Factory;
    $self->{_WORKFLOW} = $BaseWorkflow;    
    $self->{_CURRENT_ACTION} = '';
    

    #additional infos from database:
    my $count_try = (defined($wfData->{count_try}))?$wfData->{count_try}:0;
    $self->count_try($count_try);
    ##! 16: 'count try: '.$count_try

    
    #ensure that 'proc_state' is always defined:
    my $proc_state = ($wfData->{proc_state})?$wfData->{proc_state}:'init';
    $self->proc_state($proc_state);
    if($proc_state eq 'init'){
        $self->_set_proc_state( $proc_state );#saves wf state to DB
    }
    
    return $self;
}




sub execute_action {
    my ( $self, $action_name, $autorun ) = @_;
    ##! 1: 'execute_action '.$action_name
    
     $self->set_reap_at_interval($default_reap_at_interval);
    
    my $session_info = CTX('session')->export_serialized_info();
    ##! 32: 'session_info: '.$session_info
    $self->session_info($session_info);
    
    #set "reap at" info
    my $action = $self->_get_action($action_name);
    
    $self->{_CURRENT_ACTION} = $action_name;
    $self->context->param( wf_current_action => $action_name );
    
    #reset kontext-key exception
    $self->context->param( wf_exception => '' ) if $self->context->param('wf_exception');
    
    #check and handle current proc_state:
    $self->_handle_proc_state($action_name);
    
    my $reap_at_interval = (blessed( $action ) && $action->isa('OpenXPKI::Server::Workflow::Activity'))?
                               $action->get_reap_at_intervall()
                            :  $default_reap_at_interval;
    
    $self->set_reap_at_interval($reap_at_interval);
    
    ##! 16: 'set proc_state "running"'
    $self->_set_proc_state('running');#saves wf state and other infos to DB
    

    my $state='';
    # the double eval construct is used, because the handling of a caught pause throws a runtime error as real exception, 
    # if some strange error in the process flow ocurred (for example, if somebody manually "throws" a OpenXPKI::Server::Workflow::Pause object)
    
    eval { 
        eval{
            $state = $self->SUPER::execute_action( $action_name, $autorun );
            
        };
        my $e;
        if(Exception::Class->caught('OpenXPKI::Server::Workflow::Pause')){
            if ( $self->_has_paused() ) {
                #proc-state is 'pause', db-commit already done, so lets return:
                ##! 16: 'caught: OpenXPKI::Server::Workflow::Pause'
                
            }else{
                #this should NEVER happen:
                OpenXPKI::Exception->throw (
                        message => "I18N_OPENXPKI_SERVER_WORKFLOW_RUNTIME_ERROR",
                        params => {description => 'OpenXPKI::Server::Workflow::Pause thrown and caught, but workflow has not paused!'}                        
                    );
                };
        }elsif($e = Exception::Class->caught()){
            #any other exceptions will be passed to the outer eval
            ##! 128: 'Exception (no pause) caught and rethrown'
            ref $e ? $e->rethrow : croak $e;
        }
         
    };
    ##! 16: 'state after super::execute_action '.$state
    if ($EVAL_ERROR) {
        my $error = $EVAL_ERROR;
        $self->_proc_state_exception($error);

        # Don't use 'workflow_error' here since $error should already
        # be a Workflow::Exception object or subclass
        croak $error;

    }elsif($self->_has_paused()){
        return $state;
    }else {
        #reset "count_try"
        $self->count_try(0);
        
        #determine proc_state: do we still hace actions to do?
        my $proc_state = ( $self->get_current_actions ) ? 'manual' : 'finished';
        $self->_set_proc_state($proc_state);    #if a follow-up action is executed, the state changes automatically to "running"
    }

    return $state;

}



sub pause {
    
    #this method will be called from within the "pause"-Method of a OpenXPKI::Server::Workflow::Activity Object
    
    my $self = shift;
    my ($cause_description,$max_retries,$retry_interval) = @_;
    
    #increase count try 
    my $count_try = $self->count_try();
    $count_try||=0;
    $count_try++;
    
    
    ##! 16: sprintf('pause because of %s, max retries %d, retry intervall %d, count try: %d ',$cause_description,$max_retries,$retry_interval,$count_try)
        
    
    #maximum exceeded?
    if($count_try > $max_retries){
        #this exception will be catched from the workflow::execute_action method
        #proc_state and notifies/history-events will be handled there
        OpenXPKI::Exception->throw(
	       message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_RETRIES_EXEEDED',
	       params => { retries => $count_try, next_proc_state => 'retry_exceeded' }
       );
    }
    
    #calc retry-intervall:
    
    my $wakeup_at = OpenXPKI::DateTime::get_validity(
    	    {		
    		VALIDITY => $retry_interval,
        	VALIDITYFORMAT => 'relativedate',
    	    },
    	)->datetime();
    ##! 16: 'Wakeup at '. $wakeup_at
    
    $self->wakeup_at($wakeup_at);
    $self->count_try($count_try);   
    $self->context->param( wf_pause_msg => $cause_description );
    $self->notify_observers( 'pause', $self->{_CURRENT_ACTION}, $cause_description );
    $self->add_history(
        Workflow::History->new(
            {
                action      => $self->{_CURRENT_ACTION},
                description => sprintf( 'PAUSED because of %s, count try %d, wakeup at %s', $cause_description ,$count_try, $wakeup_at),
                state       => $self->state(),
                user        => CTX('session')->get_user(),
            }
        )
    );
    $self->_set_proc_state('pause');#saves wf data
}

sub set_reap_at_interval{
    my ($self, $interval) = @_;
    
    ##! 16: sprintf('set retry intervall to %s',$interval )
    
    my $reap_at = OpenXPKI::DateTime::get_validity(
    	    {		
    		VALIDITY => $interval,
        	VALIDITYFORMAT => 'relativedate',
    	    },
    	)->datetime();
    
    $self->reap_at($reap_at);
    #if the wf is already running, immediately save data to db:
    $self->_save() if $self->is_running();
}

sub _handle_proc_state{
    my ( $self, $action_name ) = @_;
    
    ##! 16: sprintf('action %s, handle_proc_state %s',$action_name,$self->proc_state)
    
    my $action_needed = $known_proc_states{$self->proc_state}->{action};
    if(!$action_needed){
        
        OpenXPKI::Exception->throw (
                message => "I18N_OPENXPKI_WORKFLOW_UNKNOWN_PROC_STATE",
                params  => {DESCRIPTION => sprintf('unkown proc-state: %s',$self->proc_state)}
            );
        
    }
    if($action_needed eq 'none'){
        ##! 16: 'no action needed for proc_state '. $self->proc_state
        return;
    }
    
    #we COULD use symbolic references to method-calls here, but - for the moment - we handle it explizit:
    if($action_needed eq '_wake_up'){
        ##! 1: 'paused, call wakeup '
        $self->_wake_up($action_name);
    }elsif($action_needed eq '_resume'){
        ##! 1: 'call _resume '
        $self->_resume($action_name);
    }elsif($action_needed eq '_runtime_exception'){
        ##! 1: 'call _runtime_exception '
        $self->_runtime_exception($action_name);
    }else{
        
        OpenXPKI::Exception->throw (
                message => "I18N_OPENXPKI_WORKFLOW_UNKNOWN_PROC_STATE_ACTION",
                params  => {DESCRIPTION => sprintf('unkown action "%s" for proc-state: %s',$action_needed, $self->proc_state)}
            );
    }
    
}

sub _wake_up {
    my ( $self, $action_name ) = @_;
    eval {
        my $action = $self->_get_action($action_name);
        $self->notify_observers( 'wakeup', $action_name );
        $self->add_history(
            Workflow::History->new(
                {
                    action      => $action_name,
                    description => 'WAKEUP',
                    state       => $self->state(),
                    user        => CTX('session')->get_user(),
                }
            )
        );
        $self->_set_proc_state('wakeup');#saves wf data
        $action->wake_up($self);
    };
    if ($EVAL_ERROR) {
        my $error = $EVAL_ERROR;
        $self->_proc_state_exception( $error );

        # Don't use 'workflow_error' here since $error should already
        # be a Workflow::Exception object or subclass
        croak $error;
    }
}

sub _resume {
    my ( $self, $action_name ) = @_;
    
    eval {
        my $action = $self->_get_action($action_name);
        my $old_state = $self->proc_state();
        $self->notify_observers( 'resume', $action_name );
        $self->add_history(
            Workflow::History->new(
                {
                    action      => $action_name,
                    description => 'RESUME',
                    state       => $self->state(),
                    user        => CTX('session')->get_user(),
                }
            )
        );
        $self->_set_proc_state('resume');#saves wf data        
        $action->resume($self,$old_state);
        
    };
    if ($EVAL_ERROR) {
        my $error = $EVAL_ERROR;
        $self->_proc_state_exception(  $error );

        # Don't use 'workflow_error' here since $error should already
        # be a Workflow::Exception object or subclass
        croak $error;
    }

}

sub _runtime_exception {
    my ( $self, $action_name ) = @_;

    eval {
        my $action = $self->_get_action($action_name);
        
        $action->runtime_exception($self);
        
        OpenXPKI::Exception->throw (
                message => "I18N_OPENXPKI_WORKFLOW_RUNTIME_EXCEPTION",
                params  => {DESCRIPTION => sprintf('Action "%s" was called on Proc-State "%s".',$action_name,$self->proc_state() )}
            );
        
    };
    if ($EVAL_ERROR) {
        my $error = $EVAL_ERROR;
        $self->_proc_state_exception( $error );

        # Don't use 'workflow_error' here since $error should already
        # be a Workflow::Exception object or subclass
        croak $error;
    }

}



sub _set_proc_state{
    my $self = shift;
    my $proc_state = shift;

    ##! 20: sprintf('_set_proc_state from %s to %s, Wfl State: %s', $self->proc_state(), $proc_state, $self->{_WORKFLOW}->state());
    
    if(!$known_proc_states{$proc_state}){
            OpenXPKI::Exception->throw (
                message => "I18N_OPENXPKI_WORKFLOW_UNKNOWN_PROC_STATE",
                params  => {DESCRIPTION => sprintf('unkown proc-state: %s',$proc_state)}
            );
        
    }
    
    $self->proc_state($proc_state);
    # save current proc-state immediately to DB 
    $self->_save();
    
}

sub _proc_state_exception {
    my $self      = shift;
    my $error = shift;
    
    
    
    my ($error_code, $error_msg,  $next_proc_state);
    
    if(blessed( $error ) && $error->isa("OpenXPKI::Exception")){
        $error_msg = $error->full_message();
        $error_code = $error->message_code();
        my $params = $error->params();
        $next_proc_state = (defined $params->{__next_proc_state__})?$params->{__next_proc_state__}:'';
        ##! 128: sprintf('next proc-state defined in exception: %s',$next_proc_state)
        ##! 228: Dumper($params)
    }else{
        $error_code = $error_msg = $error;
    }
    
    # next_proc_state defaults to "exception"
    $next_proc_state = 'exception' unless $next_proc_state && $known_proc_states{$next_proc_state};
    
    #we are already in exception context, so we dont need another exception:
    eval{
        $self->context->param( wf_exception => $error_code );
        $self->_set_proc_state($next_proc_state);
        $self->notify_observers( $next_proc_state, $self->{_CURRENT_ACTION}, $error );
        $self->add_history(
            Workflow::History->new(
                {
                    action      => $self->{_CURRENT_ACTION},
                    description => sprintf( 'EXCEPTION: %s ', $error_msg ),
                    user        => CTX('session')->get_user(),
                }
            )
        );
        $self->_save();

    };
    
}

sub is_running(){
    my $self = shift;
    return ( $self->proc_state eq 'running');
}

sub _has_paused {
    my $self = shift;
    return ( $self->proc_state eq 'pause' );
}

sub _get_next_state {
    my ( $self, $action_name, $action_return ) = @_;

    if ( $self->_has_paused() ) {
        my $state = Workflow->NO_CHANGE_VALUE;
        my $msg = sprintf( 'Workflow %d, Action %s has paused, return %s', $self->id, $action_name, $state );
        ##! 16: $msg

        return $state;
    }

    return $self->SUPER::_get_next_state( $action_name, $action_return );
}

sub _save{
    my $self = shift;
    ##! 20: 'save workflow!'
    
    # do not save if we are in the startup phase of a workflow
    # Some niffy tasks create broken workflows for validating
    # parameters and we will get tons of init/exception entries
    my $proc_state = $self->proc_state;
    if ($self->{_WORKFLOW}->state() eq 'INITIAL' &&
        ($proc_state eq 'init' || $proc_state eq 'running'  || $proc_state eq'exception' )) {
    
        ##! 20: sprintf 'dont save as we are in startup phase (proc state %s) !', $proc_state ;
        return; 
    } 
    
    $self->{_FACTORY}->save_workflow($self);
    
    # If using a DBI persister with no autocommit, commit here.
    $self->{_FACTORY}->_commit_transaction($self);
}

# Override from Class::Accessor so only certain callers can set
# properties

sub set {
    my ( $self, $prop, $value ) = @_;
    my $calling_pkg = ( caller 1 )[0];
    unless ( ( $calling_pkg =~ /^OpenXPKI::Server::Workflow/ ) || ( $calling_pkg =~ /^Workflow/ ) ) {
        carp "Tried to set from: ", join ', ', caller 1;
        workflow_error "Don't try to use my private setters from '$calling_pkg'!";
    }
    $self->{$prop} = $value;
}

sub factory {
    my $self = shift;
    return $self->{_FACTORY};
}

1;
__END__

=head1 Name

OpenXPKI::Server::Workflow

=head1 Description

This is the OpenXPKI specific subclass of Workflow.

Purpose: overwrite the Method "execute_action" of the baseclass to implement the feature of "pauseing / wake-up / resuming" workflows

The workflow-table is expanded with 4 new persistent fields (see OpenXPKI::Server::DBI::Schema)

WORKFLOW_PROC_STATE
WORKFLOW_WAKEUP_AT
WORKFLOW_COUNT_TRY
WORKFLOW_REAP_AT 

Essential field is WORKFLOW_PROC_STATE, internally "proc_state". All known and possible proc_states and their follow-up actions are defined in %known_proc_states. 
"running" will be set, before SUPER::execute_action/Activity::run is called. 
After execution of one or more Activities, either "manual" (waiting for interaction)  or "finished" will be set.
If an exception occurs, the proc state "exception" is set. Also the message code (not translation) will be saved in WF context (key "wf_exception")
The two states "pause" and "retry_exceeded" concern the  "pause" feature.


=head1 Usage documentation and guidelines

Please refer to the documentation of Workflow Modul for basic usage


=head2 new

Constructor. Takes the original Workflow-Object as first argument and take all his properties - after that the object IS the original workflow.

=head2 execute_action

wrapper around super::execute_action. does some initialisation before, checks the current proc_state, trigger the "resume"/"wake_up" - hooks, 
sets the "reap_at"-timestamp, sets the proc state to "running". 

after super::execute_action() the special "OpenXPKI::Server::Workflow::Pause"-exception will be handled and some finalisation takes place.

=head2 pause

should not be called manually/explicitly. Activities should alwasd use $self->pause($msg) (= OpenXPKI::Server::Workflow::Activity::pause()).  
calculates and stores the "count_try" and "wake_up_at" information. if "max_count:_try" is exceeded, an special exception I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_RETRIES_EXEEDED will be thrown.
the given cause of pausing will be sotored in context key "wf_pause_msg". history etries are made, observers notified.


=head2 _handle_proc_state

checks the current proc state and determines the follwo up action (e.g. "pause"->"wake_up")

=head2 _wake_up

wrapper and try/catch around Activity::wake_up(). makes history entries and notifies observers. 
sets the proc_state to "wakeup".

=head2 _resume

wrapper and try/catch around Activity::resume(). makes history entries and notifies observers. 
sets the proc_state to "wakeup".


=head2 _runtime_exception

after calling Activity::runtime_exception() throws I18N_OPENXPKI_WORKFLOW_RUNTIME_EXCEPTION

=head2 _set_proc_state($state)

stores the proc_state in  the class field "proc_state" and calls $self->_save();

=head2 _proc_state_exception

is called if an exception occurs during execute_action. the code of the exception (not the translation) is stored in context key "wf_exception".
observers are notified, history written. the proc_state is set to "exception", 
if not otherwise specified (via param "next_proc_state" given to Exception::throw(), see pause() for details. Caveat: in any case the proc_state must be specified in %known_proc_states). 

=head2 _has_paused

true, if the workflow has paused (i.e. the proc state is "pause")

=head2 is_running

true, if the workflow is running(i.e. the proc state is "running")


=head2 _get_next_state

overwritten from parent Workflow class. handles the special case "pause", otherwise it calls super::_get_next_state()

=head2 factory

return a ref to the workflows factory

=head2 _save

calls $self->{_FACTORY}->save_workflow($self);

=head2 set

overwritten from parent Workflow class. adds the OpenXPKI-package to the "allowed" packages, which CAN set internal properties.

=head3 Workflow context

See documentation for 
OpenXPKI::Server::Workflow::Persister::DBI::update_workflow()
for limitations that exist for data stored in Workflow Contexts.

=head2 Activities

=head3 Creating new activities

For creating a new Workflow activity it is advisable to start with the
activity template available in OpenXPKI::Server::Workflow::Activity::Skeleton.

=head3 Authorization and access control
